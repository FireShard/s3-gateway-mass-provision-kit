#!/bin/bash
# Flash the golden S3 gateway image to an SD card and drop that card's
# GATEWAY_ID (plus optional site files) onto its boot partition, so
# it can pick it up on first boot.
#
# Run this on your provisioning workstation, NOT on a gateway Pi.
#
# ── Single card ──────────────────────────────────────────────────────────
#   sudo ./flash-and-provision.sh \
#       --image work/image-.../deb13-arm64-min.img \
#       --device /dev/sdb \
#       --gateway-id s3-gw-03 \
#       [--site-dir siteA/]                          # points directly at one site's folder
#       # --- OR, equivalently ---
#       [--site-files-root site-files/ --site siteA]  # looks up site-files/siteA/
#
# ── Batch, one CSV row per card, prompts between cards ─────────────────────
#   sudo ./flash-and-provision.sh \
#       --image work/image-.../deb13-arm64-min.img \
#       --device /dev/sdb \
#       --batch gateways.csv \
#       [--site-files-root site-files/]   # looks up site-files/<site>/ per row
#
# ── Re-provision a card without re-flashing (e.g. relabeling a spare) ─────
#   sudo ./flash-and-provision.sh --device /dev/sdb --gateway-id s3-gw-07 --no-flash
#
# gateways.csv format (header required): gateway_id,site
#   ("#" comment lines, blank lines and Excel/Windows line endings are fine)
#
# ── Line endings of the site files ──────────────────────────────────────────
# The node-list CSV and pygw_conf.py are copied the way flash-and-provision.ps1 copies them: a UTF-8 BOM
# and Windows (CRLF) line endings are removed, because the gateway runs Linux. A file saved as UTF-16 is
# refused before anything is written. --keep-line-endings copies both files byte for byte instead.
#
# ── Combined S3 + S5 image: pre-seed the two radios ───────────────────────
# The combined image has two CP210x radios (the Zigbee dongle and the OpenThread RCP) that are told
# apart by USB serial number. Give a card both serials and a new unit never has to probe them:
#   sudo ./flash-and-provision.sh ... --gateway-id s3-gw-03 \
#       --zigbee-serial 7a90707d748fed11a020e017b96ce6f8 --rcp-serial 5c11e0a9b3f24d7e8a0f6b2d1c9e4a77
# In a batch, add optional columns:  gateway_id,site,zigbee_serial,rcp_serial
# Both are optional and independent; leave them out for a plain S3 gateway. Generic serials (such as
# 0001) and a serial used on two cards are refused before anything is written. Find a radio's serial with
#   udevadm info -q property -n /dev/ttyUSB0 | grep ID_SERIAL_SHORT
#
# ── Tailscale: join the tailnet at first boot ─────────────────────────────
# An image built with Tailscale (the combined S3 + S5 image) carries a first-boot join service. Give a card
# a Tailscale auth key and it joins your tailnet by itself once it has been provisioned; the gateway then
# removes the key from the card. Put the key in a file (one line, tskey-auth-...) so it never shows up in
# the process list or your shell history:
#   sudo ./flash-and-provision.sh ... --gateway-id s3-gw-03 --tailscale-authkey-file ./tailscale.key
# The flasher looks inside the image (or, with --no-flash, the card) first and refuses a key for one that
# has no Tailscale, so a key is never left unused on a card. In batch mode the same key goes on every card:
# it must be a reusable key (a one-time key joins only the first gateway). The key sits in plain text on the
# card's boot partition until the gateway has joined, so use a pre-approved key that expires soon.
# The guided wizard (flash-and-provision-wizard.sh) asks for the key by itself when the image has Tailscale
# and hands it to this script in the TAILSCALE_AUTHKEY environment variable.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/site-files.sh"
[ -r "$LIB" ] || { echo "ERROR: $LIB is missing - keep the host/lib folder next to this script." >&2; exit 1; }

err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
# shellcheck source=lib/site-files.sh
. "$LIB"

IMAGE=""
DEVICE=""
GATEWAY_ID=""
ZIGBEE_SERIAL=""
RCP_SERIAL=""
TS_KEY_FILE=""       # --tailscale-authkey-file
TS_AUTHKEY=""        # the key to write (from the file, else $TAILSCALE_AUTHKEY); never printed in full
SITE_DIR=""
SITE=""
BATCH_CSV=""
SITE_FILES_ROOT=""
DO_FLASH=1
KEEP_LINE_ENDINGS=0

MOUNT_POINT=""      # set while the card's boot partition is mounted (see cleanup)

usage() { print_script_usage "${BASH_SOURCE[0]}"; exit "${1:-0}"; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --image|--device|--gateway-id|--zigbee-serial|--rcp-serial|--tailscale-authkey-file|--site-dir|--site|--batch|--site-files-root)
                [ $# -ge 2 ] || die "$1 needs a value."
                case "$1" in
                    --image)           IMAGE="$2" ;;
                    --device)          DEVICE="$2" ;;
                    --gateway-id)      GATEWAY_ID="$2" ;;
                    --zigbee-serial)   ZIGBEE_SERIAL="$(clean_field "$2")" ;;
                    --rcp-serial)      RCP_SERIAL="$(clean_field "$2")" ;;
                    --tailscale-authkey-file) TS_KEY_FILE="$2" ;;
                    --site-dir)        SITE_DIR="$2" ;;
                    --site)            SITE="$2" ;;
                    --batch)           BATCH_CSV="$2" ;;
                    --site-files-root) SITE_FILES_ROOT="$2" ;;
                esac
                shift 2 ;;
            --no-flash) DO_FLASH=0; shift ;;
            --keep-line-endings) KEEP_LINE_ENDINGS=1; shift ;;
            -h|--help)  usage 0 ;;
            *) err "Unknown argument: $1"; usage 1 >&2 ;;
        esac
    done
}

is_block_device() { [ -b "$1" ]; }

validate_args() {
    [ "$(id -u)" -eq 0 ] || die "Run with sudo/root (writes to a block device)."
    [ -n "$DEVICE" ] || die "--device is required."
    is_block_device "$DEVICE" || die "not a block device: $DEVICE"
    if [ "$DO_FLASH" -eq 1 ]; then
        { [ -n "$IMAGE" ] && [ -f "$IMAGE" ]; } || die "--image PATH is required unless --no-flash."
    fi

    if [ -n "$BATCH_CSV" ]; then
        [ -f "$BATCH_CSV" ] || die "batch CSV not found: $BATCH_CSV"
        if [ -n "$ZIGBEE_SERIAL" ] || [ -n "$RCP_SERIAL" ]; then
            echo "WARNING: --zigbee-serial / --rcp-serial are ignored in batch mode (the serials come from each CSV row)." >&2
        fi
        return 0
    fi

    [ -n "$GATEWAY_ID" ] || die "--gateway-id or --batch CSV is required."
    is_valid_gateway_id "$GATEWAY_ID" \
        || die "'$GATEWAY_ID' is not a valid Gateway ID (letters, digits and '-' only, max 63 characters, no '-' at the start or end - it becomes the Pi's hostname)."

    local problem bad=0
    while IFS= read -r problem; do
        [ -n "$problem" ] || continue
        err "$problem."; bad=1
    done < <(radio_serial_problems "$ZIGBEE_SERIAL" "$RCP_SERIAL")
    [ "$bad" -eq 0 ] || die "Nothing was written. Fix the radio serial(s) above and run again."

    # --site-files-root only does anything together with --site (it picks
    # $SITE_FILES_ROOT/$SITE); say so instead of silently copying nothing.
    if [ -z "$SITE_DIR" ] && [ -n "$SITE_FILES_ROOT" ] && [ -n "$SITE" ]; then
        SITE_DIR="$SITE_FILES_ROOT/$SITE"
    fi
    if [ -z "$SITE_DIR" ] && { [ -n "$SITE_FILES_ROOT" ] || [ -n "$SITE" ]; }; then
        echo "WARNING: --site-files-root and --site only work together (single-card mode), or --site-files-root with --batch. No site files will be copied." >&2
    fi
}

# --- Tailscale auth key --------------------------------------------------------
# load_tailscale_key  sets TS_AUTHKEY from --tailscale-authkey-file, else from $TAILSCALE_AUTHKEY (how
# the wizard hands it over: an argument would show up in the process list). Stops before anything is
# written when the key is not a usable auth key.
load_tailscale_key() {
    local line problem=""
    TS_AUTHKEY=""
    if [ -n "$TS_KEY_FILE" ]; then
        [ -r "$TS_KEY_FILE" ] || die "cannot read the Tailscale key file: $TS_KEY_FILE"
        while IFS= read -r line || [ -n "$line" ]; do
            line="$(clean_field "${line%$'\r'}")"
            case "$line" in ""|"#"*) continue ;; esac
            TS_AUTHKEY="$line"; break
        done < "$TS_KEY_FILE"
        [ -n "$TS_AUTHKEY" ] || die "the Tailscale key file is empty: $TS_KEY_FILE"
    elif [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
        TS_AUTHKEY="$(clean_field "$TAILSCALE_AUTHKEY")"
    fi
    unset TAILSCALE_AUTHKEY          # no child process (rpi-imager, dd, mount) needs it
    [ -n "$TS_AUTHKEY" ] || return 0
    problem="$(tailscale_authkey_problem "$TS_AUTHKEY")"
    [ -z "$problem" ] || die "Tailscale auth key: $problem. Nothing was written."
}

# check_tailscale_target  a key is only useful when the card will have Tailscale and its first-boot join
# service: look inside the image (or, with --no-flash, the card). Stops before anything is written if not.
check_tailscale_target() {
    local state what
    [ -n "$TS_AUTHKEY" ] || return 0
    if [ "$DO_FLASH" -eq 1 ]; then
        what="the image $(basename "$IMAGE")"; state="$(tailscale_in_image "$IMAGE")"
    elif [ -n "$BATCH_CSV" ]; then
        return 0                      # a different card each time: nothing to look at up front
    else
        what="the card $DEVICE"; state="$(tailscale_on_card "$DEVICE")"
    fi
    case "$state" in
        yes) ;;
        no)  die "A Tailscale auth key was given, but $what has no Tailscale (or no first-boot join service), so the key would sit unused on the card. Nothing was written. Use an image built with Tailscale, or leave the key out." ;;
        *)   echo "WARNING: could not look inside $what to check that it has Tailscale (needs 'debugfs' from e2fsprogs); writing the key anyway." >&2 ;;
    esac
    if [ -n "$BATCH_CSV" ]; then
        echo "NOTE: the same Tailscale auth key goes on every card in this batch, so it must be a reusable key." >&2
    fi
}

# --- site folders --------------------------------------------------------------
# check_text_encoding DIR LABEL  (after site_inspect) -> returns 1 if the node list or pygw_conf.py is
# saved as UTF-16: the gateway cannot read it, and it cannot be converted safely. Skipped with --keep-line-endings.
check_text_encoding() {
    local dir="$1" label="$2" f sig
    [ "$KEEP_LINE_ENDINGS" -eq 0 ] || return 0
    for f in "${SITE_FOUND[@]}"; do
        case "$f" in required-*gw.zip) continue ;; esac
        sig="$(head -c 2 "$dir/$f" | od -An -tx1 | tr -d ' \n')"
        if [ "$sig" = "fffe" ] || [ "$sig" = "feff" ]; then
            err "$label: $f is saved as UTF-16 - re-save it as UTF-8 (plain CSV, or \"CSV UTF-8\" in Excel)."
            return 1
        fi
    done
    return 0
}

# check_site DIR LABEL  -> returns 1 (after printing why) if the folder cannot be used.
# A named site folder that is missing or empty is an error, not something to skip
# quietly: a typo would otherwise give the card the image's sample node list.
check_site() {
    local dir="$1" label="$2" e
    [ -n "$dir" ] || return 0
    if [ ! -d "$dir" ]; then
        err "$label: site folder not found: $dir"
        return 1
    fi
    if site_inspect "$dir"; then
        check_text_encoding "$dir" "$label" || return 1
        return 0
    fi
    if [ "${#SITE_ERRORS[@]}" -gt 0 ]; then
        for e in "${SITE_ERRORS[@]}"; do err "$label: $e"; done
    else
        err "$label: $dir has none of the expected files (node-list .csv, pygw_conf.py, required-*gw.zip)."
    fi
    return 1
}

# --- one card ------------------------------------------------------------------
confirm_device() {
    local answer
    echo
    echo "About to write to: $DEVICE"
    lsblk -o NAME,SIZE,MODEL,MOUNTPOINT "$DEVICE" || true
    echo
    read -r -p "Type the device path again to confirm ($DEVICE): " answer || die "Input closed - nothing was written."
    [ "$answer" = "$DEVICE" ] || die "Confirmation did not match. Aborting."
}

unmount_card() {
    local node
    while read -r node; do
        umount "$node" 2>/dev/null || true
    done < <(lsblk -nrpo NAME "$DEVICE" 2>/dev/null)
}

flash_image() {
    echo "==> Flashing $IMAGE to $DEVICE"
    unmount_card
    if command -v rpi-imager >/dev/null 2>&1; then
        rpi-imager --cli "$IMAGE" "$DEVICE"
    else
        dd if="$IMAGE" of="$DEVICE" bs=4M conv=fsync status=progress
    fi
    sync
    udevadm settle || true
    partprobe "$DEVICE" 2>/dev/null || true
    sleep 2
}

# /dev/sdX -> /dev/sdX1, /dev/mmcblk0 -> /dev/mmcblk0p1 (empty if neither exists)
boot_partition_of() {
    local dev="$1"
    if is_block_device "${dev}1"; then
        echo "${dev}1"
    elif is_block_device "${dev}p1"; then
        echo "${dev}p1"
    fi
}

# Runs on any exit (including a failed copy under set -e): never leave the card mounted.
cleanup() {
    if [ -n "$MOUNT_POINT" ]; then
        umount "$MOUNT_POINT" 2>/dev/null || true
        rmdir "$MOUNT_POINT" 2>/dev/null || true
        MOUNT_POINT=""
    fi
}

# The provision folder is ours alone: drop everything an earlier run left there so
# a card re-provisioned for another gateway or site cannot keep the old site's files.
clear_provision_dir() {
    local pdir="$1"
    rm -f "$pdir"/provision.env "$pdir"/pygw_conf.py "$pdir"/*.csv "$pdir"/required-*gw.zip
}

# copy_text_file SRC DEST  removes a UTF-8 BOM and CRLF line endings (same result as the Windows script),
# or copies byte for byte with --keep-line-endings.
copy_text_file() {
    if [ "$KEEP_LINE_ENDINGS" -eq 1 ]; then
        cp "$1" "$2"
    else
        LC_ALL=C sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$1" > "$2"
    fi
}

copy_site_files() { # site_dir provision_dir
    local site_dir="$1" pdir="$2" csv_name zip
    [ -n "$site_dir" ] || return 0

    csv_name="$(site_csv_name "$site_dir")"     # already validated by check_site
    if [ -f "$site_dir/$csv_name" ]; then copy_text_file "$site_dir/$csv_name" "$pdir/$csv_name"; fi
    if [ -f "$site_dir/pygw_conf.py" ]; then copy_text_file "$site_dir/pygw_conf.py" "$pdir/pygw_conf.py"; fi
    for zip in "$site_dir"/required-*gw.zip; do
        if [ -e "$zip" ]; then cp "$zip" "$pdir/"; fi
    done
}

provision_card() { # gateway_id site_dir [zigbee_serial] [rcp_serial] [tailscale_authkey]
    local gw_id="$1" site_dir="$2" zb="${3:-}" rcp="${4:-}" ts="${5:-}" bootpart pdir shown
    bootpart="$(boot_partition_of "$DEVICE")"
    [ -n "$bootpart" ] || die "could not find the boot partition on $DEVICE"

    MOUNT_POINT="$(mktemp -d)"
    mount "$bootpart" "$MOUNT_POINT"

    pdir="$MOUNT_POINT/$PROVISION_DIR_NAME"
    mkdir -p "$pdir"
    clear_provision_dir "$pdir"
    copy_site_files "$site_dir" "$pdir"
    # Written last: an interrupted run leaves a card with NO provision.env, which
    # first boot refuses loudly, instead of a half-provisioned one.
    provision_env_text "$gw_id" "$zb" "$rcp" "$ts" > "$pdir/provision.env"

    sync
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    MOUNT_POINT=""
    shown="GATEWAY_ID=$gw_id"
    if [ -n "$zb" ]; then shown="$shown, ZIGBEE_SERIAL=$zb"; fi
    if [ -n "$rcp" ]; then shown="$shown, RCP_SERIAL=$rcp"; fi
    if [ -n "$ts" ]; then shown="$shown, TAILSCALE_AUTHKEY=$(mask_tailscale_authkey "$ts")"; fi
    echo "==> Wrote provision.env ($shown) to $bootpart"
}

do_one_card() { # gateway_id site_dir [zigbee_serial] [rcp_serial]
    local gw_id="$1" site_dir="$2" zb="${3:-}" rcp="${4:-}"
    confirm_device
    if [ "$DO_FLASH" -eq 1 ]; then flash_image; fi
    provision_card "$gw_id" "$site_dir" "$zb" "$rcp" "$TS_AUTHKEY"
    echo "==> Done: $DEVICE -> $gw_id"
}

# --- modes ---------------------------------------------------------------------
run_single() {
    check_site "$SITE_DIR" "site files" || die "Nothing was written. Fix the site files above and run again."
    do_one_card "$GATEWAY_ID" "$SITE_DIR" "$ZIGBEE_SERIAL" "$RCP_SERIAL"
}

run_batch() {
    local i n site_dir bad=0 ignored_sites=0
    read_gateway_csv "$BATCH_CSV" || die "Fix the CSV problems above and run again. Nothing was written."
    n="${#B_ID[@]}"

    # Check every site folder named in the list before the first card is written.
    for ((i = 0; i < n; i++)); do
        [ -n "${B_SITE[i]}" ] || continue
        if [ -z "$SITE_FILES_ROOT" ]; then ignored_sites=1; continue; fi
        check_site "$SITE_FILES_ROOT/${B_SITE[i]}" "${B_ID[i]} (site ${B_SITE[i]})" || bad=1
    done
    [ "$bad" -eq 0 ] || die "Nothing was written. Fix the site files above and run again."
    if [ "$ignored_sites" -eq 1 ]; then
        echo "WARNING: the CSV names sites but --site-files-root was not given, so no site files will be copied." >&2
    fi

    for ((i = 0; i < n; i++)); do
        site_dir=""
        if [ -n "$SITE_FILES_ROOT" ] && [ -n "${B_SITE[i]}" ]; then site_dir="$SITE_FILES_ROOT/${B_SITE[i]}"; fi
        echo
        echo "############################################################"
        echo "# Card $((i + 1)) of $n: gateway_id=${B_ID[i]}  site=${B_SITE[i]:-<none>}"
        if [ -n "${B_ZB[i]}${B_RCP[i]}" ]; then
            echo "# radios: zigbee=${B_ZB[i]:-<probe>}  rcp=${B_RCP[i]:-<probe>}"
        fi
        echo "# Insert the SD card as $DEVICE, then press Enter."
        echo "############################################################"
        read -r -p "> " _ || die "Input closed - stopped before card $((i + 1)) of $n (${B_ID[i]})."
        do_one_card "${B_ID[i]}" "$site_dir" "${B_ZB[i]}" "${B_RCP[i]}"
    done
    echo
    echo "==> Batch complete: $n card(s)."
}

main() {
    parse_args "$@"
    validate_args
    load_tailscale_key
    check_tailscale_target
    trap cleanup EXIT
    if [ -n "$BATCH_CSV" ]; then run_batch; else run_single; fi
}

# Skipped when the file is sourced (which is how the functions above get tested).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
