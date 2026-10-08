#!/bin/bash
# ============================================================================
# flash-wizard.sh - guided SD-card flashing for the S3 Zigbee Gateway image
#
# Just run it - no long commands, no options to remember:
#
#     ./host/flash-wizard.sh
#
# It asks you (one question at a time) for the golden image, the Gateway ID,
# the site (if any) and the SD card, shows a summary, and then runs
# host/flash-and-provision.sh with the right arguments. That script still asks
# you to re-type the device path before anything is written.
#
# What it adds on top of flash-and-provision.sh:
#   * only offers removable / SD-card devices, and never your own system disk,
#     the disk the image or kit lives on, or a card that is too small;
#   * checks the Gateway ID, warns if an ID was already used, suggests the
#     next number;
#   * checks the site folder has the expected files (a wrong folder name would
#     otherwise be silently ignored);
#   * batch mode from a CSV (comment lines and Excel/Windows line endings are
#     fine) that skips cards already done;
#   * waits for you to remove each card before the next one (so a card can't be
#     flashed twice by mistake);
#   * keeps a record in host/flash-log.csv.
#
# Optional flags (normally not needed):
#   --image PATH            use this golden image (.img) instead of searching
#   --site-files-root DIR   folder holding one sub-folder per site
#                           (default: host/site-files)
#   -h, --help              show this text
#
# Optional: put the checksum next to the image as <image>.img.sha256 (the
# output of `sha256sum`) and the wizard verifies it before flashing.
# ============================================================================

shopt -s nullglob
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FLASHER="$SCRIPT_DIR/flash-and-provision.sh"
SITE_ROOT="$SCRIPT_DIR/site-files"
LOG_FILE="$SCRIPT_DIR/flash-log.csv"
LOG_HEADER="timestamp,operator,gateway_id,site,result,image,card_model,card_gb,device"
MAX_CARD_GB=256                 # anything bigger is not offered as an SD card
MIN_IMAGE_BYTES=$((16 * 1024 * 1024))
ID_RE='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'

IMAGE=""
IMAGE_BYTES=0
IMAGE_OK=0
LAST_ID=""
LAST_SITE=""
LAST_SITE_DIR=""
FLASHING=0
LOG_OK=1

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# --- become root (the flasher writes to block devices) -----------------------
if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "This tool needs administrator rights and 'sudo' was not found." >&2
        exit 1
    fi
    echo "Administrator rights are needed to write to SD cards."
    echo "You may be asked for your password."
    exec sudo bash "$0" "$@"
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="${2:-}"; shift 2 ;;
        --site-files-root) SITE_ROOT="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1 (run with --help)" >&2; exit 1 ;;
    esac
done

OPERATOR="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
OPERATOR_HOME="$(getent passwd "$OPERATOR" 2>/dev/null | cut -d: -f6)"

# --- output helpers ----------------------------------------------------------
if [ -t 1 ]; then
    BOLD=$'\e[1m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi
say()  { printf '%s\n' "$*"; }
head1(){ printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '%s%s%s\n' "$GREEN" "$*" "$RESET"; }
warn() { printf '%sWARNING: %s%s\n' "$YELLOW" "$*" "$RESET"; }
err()  { printf '%sERROR: %s%s\n' "$RED" "$*" "$RESET" >&2; }
rule() { printf '  %s\n' "------------------------------------------------------------------"; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}
# Clean a path typed or drag-and-dropped into the terminal.
clean_path() {
    local s
    s="$(trim "$1")"
    s="${s#\'}"; s="${s%\'}"; s="${s#\"}"; s="${s%\"}"
    s="${s//\\ / }"
    printf '%s' "$s"
}
human() {
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=si --suffix=B --format='%.1f' "$1" 2>/dev/null && return
    fi
    awk -v b="$1" 'BEGIN{printf "%.1fGB", b/1e9}'
}
# kv KEY 'lsblk -P line' -> value (parsed with a regex, never eval'd)
kv() {
    local re="$1=\"([^\"]*)\""
    if [[ $2 =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

ANSWER=""
ask() { # ask "Question" [default]  -> $ANSWER
    local prompt="$1" def="${2:-}" a
    [ -n "$def" ] && prompt="$prompt [$def]"
    if ! read -r -e -p "$prompt: " a; then
        echo; err "Input closed - exiting."; exit 1
    fi
    a="$(trim "$a")"
    ANSWER="${a:-$def}"
}
ask_yn() { # ask_yn "Question" Y|N -> 0 for yes, 1 for no
    local def="${2:-Y}" hint a
    if [ "$def" = "Y" ]; then hint="Y/n"; else hint="y/N"; fi
    while true; do
        if ! read -r -e -p "$1 [$hint]: " a; then
            echo; err "Input closed - exiting."; exit 1
        fi
        a="$(trim "$a")"; a="${a,,}"
        [ -z "$a" ] && a="${def,,}"
        case "$a" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) say "Please answer y or n." ;;
        esac
    done
}

on_interrupt() {
    echo
    if [ "$FLASHING" = 1 ]; then
        warn "Interrupted while writing. That SD card is NOT usable - flash it again."
    else
        say "Cancelled."
    fi
    exit 130
}
trap on_interrupt INT

# --- record keeping ----------------------------------------------------------
init_log() {
    LOG_OK=1
    if [ ! -f "$LOG_FILE" ]; then
        if ! printf '%s\n' "$LOG_HEADER" > "$LOG_FILE" 2>/dev/null; then
            LOG_OK=0
            warn "Cannot create $LOG_FILE - flashes will not be recorded."
            return
        fi
        [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$LOG_FILE" 2>/dev/null
    fi
    if [ ! -w "$LOG_FILE" ]; then
        LOG_OK=0
        warn "Cannot write to $LOG_FILE - flashes will not be recorded."
    fi
}
csvf() { local v="${1//,/ }"; v="${v//$'\n'/ }"; printf '%s' "$v"; }
log_row() { # result gateway_id site card_model card_bytes device
    [ "$LOG_OK" = 1 ] || return 0
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$(csvf "$OPERATOR")" "$(csvf "$2")" \
        "$(csvf "${3:-none}")" "$1" "$(csvf "$(basename "${IMAGE:-none}")")" \
        "$(csvf "$4")" "$(( ${5:-0} / 1000000000 ))" "$(csvf "$6")" >> "$LOG_FILE"
}
prior_use() { # prior_use ID -> prints the timestamp of an earlier successful use
    [ -f "$LOG_FILE" ] || return 1
    awk -F, -v id="${1,,}" '
        NR>1 && tolower($3)==id && ($5=="FLASHED" || $5=="RELABELED") {t=$1}
        END {if (t != "") print t; else exit 1}' "$LOG_FILE"
}
last_logged_id() {
    [ -f "$LOG_FILE" ] || return 0
    awk -F, 'NR>1 && ($5=="FLASHED" || $5=="RELABELED") {id=$3} END {print id}' "$LOG_FILE"
}
next_id() { # s3-gw-03 -> s3-gw-04 (keeps zero padding); fails if no trailing number
    local id="$1" prefix digits
    [[ $id =~ ^(.*[^0-9])?([0-9]+)$ ]] || return 1
    prefix="${BASH_REMATCH[1]}"; digits="${BASH_REMATCH[2]}"
    printf '%s%0*d' "$prefix" "${#digits}" "$((10#$digits + 1))"
}

# --- the golden image --------------------------------------------------------
find_images() {
    local d f
    local -a dirs=("$SCRIPT_DIR" "$KIT_DIR" "$KIT_DIR/image" "$KIT_DIR/images" "$PWD")
    if [ -n "$OPERATOR_HOME" ]; then dirs+=("$OPERATOR_HOME/Downloads" "$OPERATOR_HOME/Desktop"); fi
    for d in "${dirs[@]}"; do
        for f in "$d"/*.img; do
            [ -f "$f" ] && readlink -f "$f"
        done
    done | sort -u
}
image_line() {
    local f="$1"
    printf '%s (%s, %s) in %s' "$(basename "$f")" "$(human "$(stat -c%s "$f")")" \
        "$(date -d "@$(stat -c%Y "$f")" '+%Y-%m-%d')" "$(dirname "$f")"
}
verify_image() {
    local f="$1" size sig want got
    if [ ! -f "$f" ]; then err "File not found: $f"; return 1; fi
    case "${f,,}" in
        *.xz|*.gz|*.zip|*.zst|*.bz2|*.7z|*.tar|*.tgz)
            err "This looks like a compressed file. Extract it first so you have a plain .img file."
            return 1 ;;
    esac
    size="$(stat -c%s "$f")"
    if [ "$size" -lt "$MIN_IMAGE_BYTES" ]; then
        err "$(basename "$f") is only $(human "$size") - too small to be the golden image."
        return 1
    fi
    sig="$(od -An -tx1 -j510 -N2 "$f" 2>/dev/null | tr -d ' \n')"
    if [ "$sig" != "55aa" ]; then
        err "$(basename "$f") does not look like a Raspberry Pi disk image (wrong file?)."
        return 1
    fi
    local lower="${f,,}"
    if [ "${lower%.img}" = "$lower" ]; then
        warn "The file name does not end in .img."
        ask_yn "Use it anyway?" N || return 1
    fi
    if [ -f "$f.sha256" ]; then
        say "Checking the image checksum (this takes a moment)..."
        want="$(awk 'NR==1{print tolower($1)}' "$f.sha256")"
        got="$(sha256sum "$f" | awk '{print $1}')"
        if [ "$want" != "$got" ]; then
            err "CHECKSUM MISMATCH - this image is damaged or is not the approved one. Do not use it."
            say "  expected: $want"
            say "  actual:   $got"
            return 1
        fi
        ok "Checksum OK."
    else
        say "(No $(basename "$f").sha256 file next to the image - checksum check skipped.)"
    fi
    IMAGE="$f"
    IMAGE_BYTES="$size"
    IMAGE_OK=1
    return 0
}
ensure_image() {
    [ "$IMAGE_OK" = 1 ] && return 0
    local -a found=()
    local i pick
    if [ -n "$IMAGE" ]; then
        verify_image "$(clean_path "$IMAGE")" || { IMAGE=""; return 1; }
        return 0
    fi
    mapfile -t found < <(find_images)
    if [ "${#found[@]}" -eq 1 ]; then
        say "Found this golden image:"
        say "  $(image_line "${found[0]}")"
        if ask_yn "Use it?" Y; then
            verify_image "${found[0]}" && return 0
            # verification failed (bad checksum, too small, wrong signature) -
            # fall through to the manual prompt below rather than dead-ending.
        fi
    elif [ "${#found[@]}" -gt 1 ]; then
        say "Several image files were found:"
        for i in "${!found[@]}"; do printf '  %d) %s\n' "$((i + 1))" "$(image_line "${found[i]}")"; done
        ask "Choose the image number, or type/drag in another path"
        pick="$ANSWER"
        if [[ $pick =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#found[@]}" ]; then
            verify_image "${found[pick-1]}" && return 0
        else
            verify_image "$(clean_path "$pick")" && return 0
        fi
    fi
    say "Type the path of the golden image (.img) file, or drag the file into this window."
    ask "Image file (or q to go back)"
    [ "$ANSWER" = "q" ] && return 1
    verify_image "$(clean_path "$ANSWER")"
}

# --- finding the SD card -----------------------------------------------------
PROTECTED=()
CARD_DEV=(); CARD_BYTES=(); CARD_MODEL=(); CARD_TRAN=(); CARD_LABELS=()
DEVICE=""; DEVICE_BYTES=0; DEVICE_MODEL=""

top_disk() { # /dev/sda2 -> /dev/sda (follows partitions, LVM, crypt)
    local d="$1" p
    d="${d%%\[*}"
    [ -e "$d" ] || return 1
    while p="$(lsblk -dno PKNAME "$d" 2>/dev/null | head -n1)"; [ -n "$p" ]; do
        d="/dev/$p"
    done
    printf '%s' "$d"
}
compute_protected() { # disks that must never be offered
    PROTECTED=()
    local p src td
    for p in / "$KIT_DIR" "$SCRIPT_DIR" "$PWD" "$IMAGE" "$LOG_FILE"; do
        [ -n "$p" ] || continue
        [ -e "$p" ] || p="$(dirname "$p")"
        src="$(findmnt -no SOURCE -T "$p" 2>/dev/null | head -n1)"
        src="${src%%\[*}"
        [ "${src:0:5}" = "/dev/" ] || continue
        if td="$(top_disk "$src")"; then PROTECTED+=("$td"); fi
    done
}
is_protected() {
    local dev="$1" p line mp
    for p in "${PROTECTED[@]}"; do [ "$p" = "$dev" ] && return 0; done
    while IFS= read -r line; do
        mp="$(kv MOUNTPOINT "$line")"
        case "$mp" in
            /|/boot|/boot/efi|/boot/firmware|/home|/usr|/var|/opt|/srv|/etc|"[SWAP]") return 0 ;;
        esac
    done < <(lsblk -nPo MOUNTPOINT "$dev" 2>/dev/null)
    return 1
}
labels_of() {
    local line l out=""
    while IFS= read -r line; do
        l="$(kv LABEL "$line")"
        [ -n "$l" ] && out="${out:+$out, }$l"
    done < <(lsblk -nPo LABEL "$1" 2>/dev/null)
    printf '%s' "$out"
}
scan_cards() {
    CARD_DEV=(); CARD_BYTES=(); CARD_MODEL=(); CARD_TRAN=(); CARD_LABELS=()
    compute_protected
    local line dev size type tran rm model max=$((MAX_CARD_GB * 1000 * 1000 * 1000))
    while IFS= read -r line; do
        dev="$(kv NAME "$line")"; size="$(kv SIZE "$line")"; type="$(kv TYPE "$line")"
        tran="$(kv TRAN "$line")"; rm="$(kv RM "$line")"; model="$(trim "$(kv MODEL "$line")")"
        [ "$type" = "disk" ] || continue
        [[ $size =~ ^[0-9]+$ ]] || continue
        [ "$size" -gt 0 ] || continue                       # empty reader slot
        [ "$size" -le "$max" ] || continue                  # too big to be an SD card
        if [ "$tran" != "usb" ] && [ "$rm" != "1" ] && [[ $dev != /dev/mmcblk* ]]; then continue; fi
        is_protected "$dev" && continue
        CARD_DEV+=("$dev"); CARD_BYTES+=("$size"); CARD_MODEL+=("${model:-unknown card reader}")
        CARD_TRAN+=("${tran:-mmc}"); CARD_LABELS+=("$(labels_of "$dev")")
    done < <(lsblk -dnpPb -o NAME,SIZE,TYPE,TRAN,RM,MODEL 2>/dev/null)
}
card_present() {
    local s
    s="$(blockdev --getsize64 "$1" 2>/dev/null)" || return 1
    [[ $s =~ ^[0-9]+$ ]] && [ "$s" -gt 0 ]
}
card_line() { # index
    local i="$1" holds="${CARD_LABELS[$1]}"
    printf '%s  %s  %s (%s)' "${CARD_DEV[i]}" "$(human "${CARD_BYTES[i]}")" "${CARD_MODEL[i]}" "${CARD_TRAN[i]}"
    if [ -n "$holds" ]; then printf '  - currently holds: %s' "$holds"; fi
}
wait_for_card() { # returns 1 if the user types q
    local shown=0 line rc
    while true; do
        scan_cards
        if [ "${#CARD_DEV[@]}" -gt 0 ]; then sleep 1; scan_cards; return 0; fi
        if [ "$shown" = 0 ]; then
            say "Insert the SD card into the card reader (and plug the reader into this computer)."
            say "Waiting for a card... (type q and press Enter to go back)"
            shown=1
        fi
        if read -r -t 2 line; then
            [ "$line" = "q" ] && return 1
        else
            rc=$?
            [ "$rc" -gt 128 ] || return 1              # EOF: give up
        fi
    done
}
pick_card() { # $1 = "flash" (needs room for the image) or "relabel"
    local mode="$1" i n pick
    while true; do
        wait_for_card || return 1
        n="${#CARD_DEV[@]}"
        if [ "$n" -eq 1 ]; then
            say "Found this SD card:"
            say "  $(card_line 0)"
            if ask_yn "Use this card?" Y; then i=0; else
                ask_yn "Look again?" Y && continue
                return 1
            fi
        else
            say "Several possible SD cards were found:"
            for i in $(seq 0 $((n - 1))); do printf '  %d) %s\n' "$((i + 1))" "$(card_line "$i")"; done
            ask "Choose the card number (r = look again, q = go back)"
            pick="$ANSWER"
            [ "$pick" = "q" ] && return 1
            [ "$pick" = "r" ] && continue
            if ! [[ $pick =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "$n" ]; then
                err "Please type a number from the list."; continue
            fi
            i=$((pick - 1))
        fi
        if [ "$mode" = "flash" ] && [ "${CARD_BYTES[i]}" -lt "$IMAGE_BYTES" ]; then
            err "That card ($(human "${CARD_BYTES[i]}")) is smaller than the image ($(human "$IMAGE_BYTES")). Use a bigger card."
            wait_for_removal "${CARD_DEV[i]}"
            continue
        fi
        DEVICE="${CARD_DEV[i]}"; DEVICE_BYTES="${CARD_BYTES[i]}"; DEVICE_MODEL="${CARD_MODEL[i]}"
        return 0
    done
}
wait_for_removal() {
    local dev="$1" line rc
    card_present "$dev" || return 0
    say "Please remove the SD card from the reader now."
    say "(The wizard continues by itself once it is out. Press Enter to skip this check.)"
    while card_present "$dev"; do
        if read -r -t 1 line; then
            break
        else
            rc=$?
            [ "$rc" -gt 128 ] || break
        fi
    done
}

# --- Gateway ID and site -----------------------------------------------------
prompt_gateway_id() { # -> $GW_ID
    local sug="" prev
    sug="$(next_id "${LAST_ID:-$(last_logged_id)}" 2>/dev/null)"
    say "Gateway ID rules: letters, numbers and '-' only (for example s3-gw-03)."
    say "Every gateway needs its own, unique ID."
    while true; do
        ask "Gateway ID" "$sug"
        GW_ID="$ANSWER"
        if [ -z "$GW_ID" ]; then err "The Gateway ID cannot be empty."; continue; fi
        if ! [[ $GW_ID =~ $ID_RE ]]; then
            err "'$GW_ID' is not a valid Gateway ID. Use letters, numbers and '-' only (no spaces or underscores, no '-' at the start or end, max 63 characters)."
            continue
        fi
        if prev="$(prior_use "$GW_ID")"; then
            warn "'$GW_ID' was already flashed on $prev."
            ask_yn "Use this ID again anyway?" N || continue
        fi
        return 0
    done
}
site_csv_name() { # dir -> name of the node-list CSV the site's pygw_conf.py points at
    # Same rule as s3-gateway-dbup (which runs at first boot and refuses a bad
    # value): the LAST top-level `localDBpath = '<name>'` line wins and <name>
    # is [A-Za-z0-9_.-], 1-60 characters, then .csv. No pygw_conf.py in the
    # folder -> the image's own config is used -> samplelist.csv.
    # flash-and-provision.sh repeats this check before it writes a card.
    # Prints the name; on an unusable setting prints "ERROR: ..." and returns 1.
    local d="$1" conf line name
    local ok_re='^[A-Za-z0-9_.-]{1,60}\.csv$'
    local lit_re="^localDBpath[[:space:]]*=[[:space:]]*(['\"])([^'\"\\\\]*)\\1[[:space:]]*(#.*)?$"
    conf="$d/pygw_conf.py"
    if [ ! -f "$conf" ]; then echo "samplelist.csv"; return 0; fi
    line="$(tr -d '\r' < "$conf" | grep -E '^localDBpath[[:space:]]*=' | tail -n 1 || true)"
    if [ -z "$line" ]; then
        echo "ERROR: localDBpath is not set in pygw_conf.py (s3-gateway-dbup refuses a pygw_conf.py without it)."; return 1
    fi
    if ! [[ "$line" =~ $lit_re ]]; then
        echo "ERROR: localDBpath in pygw_conf.py must be a plain quoted string such as 'samplelist.csv'."; return 1
    fi
    name="${BASH_REMATCH[2]}"
    if ! [[ "$name" =~ $ok_re ]]; then
        echo "ERROR: localDBpath '$name' in pygw_conf.py must be a plain file name ending in .csv (letters, digits, . _ - only, at most 60 characters before .csv, no folders)."; return 1
    fi
    echo "$name"
}
site_inspect() { # dir -> SITE_FOUND / SITE_MISSING / SITE_ERRORS ; returns 1 if the folder cannot be used
    local d="$1" f csv
    local -a zips=()
    SITE_FOUND=(); SITE_MISSING=(); SITE_ERRORS=()
    if csv="$(site_csv_name "$d")"; then
        if [ -f "$d/$csv" ]; then
            SITE_FOUND+=("$csv")
        else
            SITE_MISSING+=("$csv")
            # The image only ships samplelist.csv. If pygw_conf.py names another file
            # and it is not here, first boot would stop at s3-gateway-dbup.
            if [ -f "$d/pygw_conf.py" ] && [ "$csv" != "samplelist.csv" ]; then
                SITE_ERRORS+=("pygw_conf.py names the node list '$csv' but that file is not in this folder (the image only ships samplelist.csv, so first boot would stop at s3-gateway-dbup).")
            fi
        fi
    else
        SITE_ERRORS+=("${csv#ERROR: }")
    fi
    if [ -f "$d/pygw_conf.py" ]; then SITE_FOUND+=("pygw_conf.py"); else SITE_MISSING+=("pygw_conf.py"); fi
    zips=("$d"/required-*gw.zip)
    if [ -e "${zips[0]}" ]; then
        for f in "${zips[@]}"; do SITE_FOUND+=("$(basename "$f")"); done
    else
        SITE_MISSING+=("required-*gw.zip")
    fi
    [ "${#SITE_ERRORS[@]}" -eq 0 ] && [ "${#SITE_FOUND[@]}" -gt 0 ]
}
join_by_comma() { local IFS=,; printf '%s' "$*" | sed 's/,/, /g'; }
pick_site() { # -> $SITE, $SITE_DIR ; returns 1 to go back
    SITE=""; SITE_DIR=""
    local -a dirs=()
    local d i pick f
    if [ -d "$SITE_ROOT" ]; then
        for d in "$SITE_ROOT"/*/; do [ -d "$d" ] && dirs+=("${d%/}"); done
    fi
    if [ "${#dirs[@]}" -eq 0 ]; then
        if ask_yn "Does this card need site-specific files (from the project team)?" N; then
            err "No site folders were found in: $SITE_ROOT"
            say "Put the site files in '$SITE_ROOT/<site name>/' and start again."
            return 1
        fi
        return 0
    fi
    if [ -n "$LAST_SITE_DIR" ] && [ -d "$LAST_SITE_DIR" ]; then
        if ask_yn "Use the same site as the last card ($LAST_SITE)?" Y; then
            SITE="$LAST_SITE"; SITE_DIR="$LAST_SITE_DIR"; return 0
        fi
    elif [ -n "$LAST_SITE" ] && [ -z "$LAST_SITE_DIR" ] && [ "$LAST_SITE" = "none" ]; then
        if ask_yn "Use the image defaults again (no site files), like the last card?" Y; then
            SITE=""; SITE_DIR=""; return 0
        fi
    fi
    while true; do
        say "Which site is this card for?"
        say "  0) No site files - use the defaults built into the image"
        for i in "${!dirs[@]}"; do printf '  %d) %s\n' "$((i + 1))" "$(basename "${dirs[i]}")"; done
        ask "Choose a number (q = go back)"
        pick="$ANSWER"
        [ "$pick" = "q" ] && return 1
        if ! [[ $pick =~ ^[0-9]+$ ]] || [ "$pick" -gt "${#dirs[@]}" ]; then
            err "Please type a number from the list."; continue
        fi
        [ "$pick" -eq 0 ] && return 0
        d="${dirs[pick-1]}"
        if ! site_inspect "$d"; then
            if [ "${#SITE_ERRORS[@]}" -gt 0 ]; then
                err "The folder '$(basename "$d")' cannot be used:"
                for f in "${SITE_ERRORS[@]}"; do err "  - $f"; done
                say "Ask the project team for corrected site files."
            else
                err "The folder '$(basename "$d")' has none of the expected files (the node-list .csv named in pygw_conf.py, pygw_conf.py, required-*gw.zip)."
            fi
            continue
        fi
        say "  Site '$(basename "$d")' will install: $(join_by_comma "${SITE_FOUND[@]}")"
        if [ "${#SITE_MISSING[@]}" -gt 0 ]; then
            warn "Not in this folder (the image default is kept): $(join_by_comma "${SITE_MISSING[@]}")"
        fi
        ask_yn "Is that the right site?" Y || continue
        SITE="$(basename "$d")"; SITE_DIR="$d"
        return 0
    done
}

# --- running the flasher -----------------------------------------------------
show_plan() { # mode id
    local mode="$1" id="$2" what
    head1 "Please check:"
    rule
    if [ "$mode" = "flash" ]; then
        printf '   %-12s %s (%s)\n' "Image" "$(basename "$IMAGE")" "$(human "$IMAGE_BYTES")"
    else
        printf '   %-12s %s\n' "Action" "write the Gateway ID only (card is NOT re-flashed)"
    fi
    printf '   %-12s %s  %s  %s\n' "SD card" "$DEVICE" "$(human "$DEVICE_BYTES")" "$DEVICE_MODEL"
    printf '   %-12s %s\n' "Gateway ID" "$id"
    if [ -n "$SITE_DIR" ]; then
        site_inspect "$SITE_DIR"
        what="$SITE ($(join_by_comma "${SITE_FOUND[@]}"))"
    else
        what="none - the defaults built into the image"
    fi
    printf '   %-12s %s\n' "Site files" "$what"
    rule
    if [ "$mode" = "flash" ]; then
        printf '   %s%s%s\n' "$RED" "EVERYTHING ON THE SD CARD WILL BE ERASED." "$RESET"
    fi
}
run_flasher() { # mode id site_dir
    local mode="$1" id="$2" site_dir="$3" rc
    local -a args=(--device "$DEVICE" --gateway-id "$id")
    if [ "$mode" = "relabel" ]; then args+=(--no-flash); else args+=(--image "$IMAGE"); fi
    if [ -n "$site_dir" ]; then args+=(--site-dir "$site_dir"); fi
    echo
    say "Starting. You will be asked to type the device path ($DEVICE) once more to confirm."
    FLASHING=1
    bash "$FLASHER" "${args[@]}"
    rc=$?
    FLASHING=0
    return "$rc"
}
finish_card() { # rc mode id
    local rc="$1" mode="$2" id="$3" result
    echo
    if [ "$rc" -eq 0 ]; then
        if [ "$mode" = "flash" ]; then result="FLASHED"; else result="RELABELED"; fi
        log_row "$result" "$id" "${SITE:-none}" "$DEVICE_MODEL" "$DEVICE_BYTES" "$DEVICE"
        LAST_ID="$id"
        LAST_SITE="${SITE:-none}"; LAST_SITE_DIR="$SITE_DIR"
        sync
        ok "DONE - card for $id is ready."
        say "  1. Wait until the card reader's light stops blinking."
        say "  2. Take the card out and label it:  $id"
        printf '\a'
        return 0
    fi
    log_row "INCOMPLETE" "$id" "${SITE:-none}" "$DEVICE_MODEL" "$DEVICE_BYTES" "$DEVICE"
    err "This card was NOT completed (it failed or was cancelled). Read the messages above."
    say "  Do not use this card until it has been flashed again successfully."
    printf '\a'
    return 1
}

# --- modes -------------------------------------------------------------------
mode_single() {
    ensure_image || return
    while true; do
        head1 "New card"
        prompt_gateway_id
        pick_site || return
        pick_card flash || return
        show_plan flash "$GW_ID"
        if ! ask_yn "Is this correct?" Y; then
            say "OK - let's start this card again."
            wait_for_removal "$DEVICE"
            continue
        fi
        run_flasher flash "$GW_ID" "$SITE_DIR"
        finish_card $? flash "$GW_ID"
        wait_for_removal "$DEVICE"
        ask_yn "Flash another card?" Y || return
    done
}

mode_relabel() {
    head1 "Change the Gateway ID on a card without re-flashing"
    say "Use this ONLY for a card that has never been started in a gateway."
    say "A gateway that has already booted keeps its ID - re-flash that card instead."
    ask_yn "Has this card NEVER been booted in a gateway?" N || {
        say "Then use option 1 (flash) to give it a new ID."; return; }
    while true; do
        prompt_gateway_id
        pick_site || return
        pick_card relabel || return
        show_plan relabel "$GW_ID"
        if ! ask_yn "Is this correct?" Y; then
            wait_for_removal "$DEVICE"
            continue
        fi
        run_flasher relabel "$GW_ID" "$SITE_DIR"
        finish_card $? relabel "$GW_ID"
        wait_for_removal "$DEVICE"
        ask_yn "Change another card?" N || return
    done
}

B_ID=(); B_SITE=()
parse_batch_csv() { # file -> B_ID / B_SITE ; returns 1 if anything is wrong
    local file="$1" line first=1 idcol=-1 sitecol=-1 i n=0 bad=0 id site seen=" " lc f
    local -a cols=()
    B_ID=(); B_SITE=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [ "$first" = 1 ]; then line="${line#$'\xef\xbb\xbf'}"; fi
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        IFS=, read -r -a cols <<< "$line"
        for i in "${!cols[@]}"; do cols[i]="$(clean_path "${cols[i]}")"; done
        if [ "$first" = 1 ]; then
            for i in "${!cols[@]}"; do
                case "${cols[i],,}" in
                    gateway_id) idcol="$i" ;;
                    site) sitecol="$i" ;;
                esac
            done
            if [ "$idcol" -lt 0 ]; then
                err "The first line of the CSV must be a header containing 'gateway_id' (for example: gateway_id,site,notes)."
                return 1
            fi
            first=0
            continue
        fi
        n=$((n + 1))
        id="${cols[idcol]:-}"; site=""
        if [ "$sitecol" -ge 0 ]; then site="${cols[sitecol]:-}"; fi
        lc="${id,,}"
        if ! [[ $id =~ $ID_RE ]]; then
            err "Row $n: '$id' is not a valid Gateway ID."; bad=1
        elif [[ $seen == *" $lc "* ]]; then
            err "Row $n: Gateway ID '$id' appears twice in the CSV."; bad=1
        fi
        seen="$seen$lc "
        if [ -n "$site" ]; then
            if [ ! -d "$SITE_ROOT/$site" ]; then
                err "Row $n ($id): site folder not found: $SITE_ROOT/$site"; bad=1
            elif ! site_inspect "$SITE_ROOT/$site"; then
                if [ "${#SITE_ERRORS[@]}" -gt 0 ]; then
                    for f in "${SITE_ERRORS[@]}"; do err "Row $n ($id): site '$site': $f"; done
                else
                    err "Row $n ($id): site folder '$site' has none of the expected files."
                fi
                bad=1
            fi
        fi
        B_ID+=("$id"); B_SITE+=("$site")
    done < "$file"
    if [ "$first" = 1 ]; then err "The CSV file is empty."; return 1; fi
    if [ "${#B_ID[@]}" -eq 0 ]; then err "The CSV has a header but no cards."; return 1; fi
    [ "$bad" = 0 ]
}
mode_batch() {
    local csv i n skip_done=0 done_count=0 ok_n=0 fail_n=0 skip_n=0 site_dir act
    ensure_image || return
    head1 "Batch from a CSV list"
    say "The CSV needs a header line (gateway_id,site,notes) and one line per card."
    if [ -f "$SCRIPT_DIR/gateways.csv" ]; then
        ask "CSV file" "$SCRIPT_DIR/gateways.csv"
    else
        ask "CSV file (type or drag it in, q = go back)"
    fi
    [ "$ANSWER" = "q" ] && return
    csv="$(clean_path "$ANSWER")"
    [ -f "$csv" ] || { err "File not found: $csv"; return; }
    parse_batch_csv "$csv" || { say "Fix the problems above in the CSV and start again."; return; }
    n="${#B_ID[@]}"
    say "The list has $n card(s):"
    for i in $(seq 0 $((n - 1))); do
        act=""
        if prior_use "${B_ID[i]}" >/dev/null; then act="  (already flashed before)"; done_count=$((done_count + 1)); fi
        printf '  %2d) %-24s site: %s%s\n' "$((i + 1))" "${B_ID[i]}" "${B_SITE[i]:-none}" "$act"
    done
    if [ "$done_count" -gt 0 ]; then
        if ask_yn "$done_count card(s) were already flashed. Skip those?" Y; then skip_done=1; fi
    fi
    ask_yn "Start the batch?" Y || return
    for i in $(seq 0 $((n - 1))); do
        GW_ID="${B_ID[i]}"; SITE="${B_SITE[i]}"; SITE_DIR=""
        [ -n "$SITE" ] && SITE_DIR="$SITE_ROOT/$SITE"
        if [ "$skip_done" = 1 ] && prior_use "$GW_ID" >/dev/null; then
            skip_n=$((skip_n + 1)); continue
        fi
        head1 "Card $((i + 1)) of $n:  $GW_ID   (site: ${SITE:-none})"
        while true; do
            pick_card flash || { say "Batch stopped."; batch_summary "$ok_n" "$fail_n" "$skip_n" "$n"; return; }
            show_plan flash "$GW_ID"
            ask "Press Enter to start, s = skip this card, q = stop the batch"
            case "${ANSWER,,}" in
                s) skip_n=$((skip_n + 1)); wait_for_removal "$DEVICE"; continue 2 ;;
                q) wait_for_removal "$DEVICE"; batch_summary "$ok_n" "$fail_n" "$skip_n" "$n"; return ;;
                "") ;;
                *) say "Please press Enter, s or q."; continue ;;
            esac
            run_flasher flash "$GW_ID" "$SITE_DIR"
            if finish_card $? flash "$GW_ID"; then ok_n=$((ok_n + 1)); else fail_n=$((fail_n + 1)); fi
            wait_for_removal "$DEVICE"
            break
        done
    done
    batch_summary "$ok_n" "$fail_n" "$skip_n" "$n"
}
batch_summary() {
    head1 "Batch finished"
    say "  Flashed OK : $1"
    say "  Not completed : $2"
    say "  Skipped    : $3"
    say "  In the list: $4"
    if [ "$2" -gt 0 ]; then warn "Some cards were not completed - see the messages above and the log (option 4)."; fi
}

show_log() {
    if [ ! -s "$LOG_FILE" ]; then say "Nothing has been recorded yet."; return; fi
    head1 "Last 20 flashes (full record: $LOG_FILE)"
    { head -n 1 "$LOG_FILE"; tail -n +2 "$LOG_FILE" | tail -n 20; } | awk -F, '
        { printf "  %-19s %-10s %-16s %-10s %-11s %s\n", $1, $2, $3, $4, $5, $7 }'
}

main_menu() {
    local choice
    while true; do
        head1 "S3 Gateway - SD card flashing"
        say "  1) Flash SD cards, one at a time"
        say "  2) Flash a batch from a CSV list"
        say "  3) Change the Gateway ID on a card that has never been booted"
        say "  4) Show what has been flashed"
        say "  q) Quit"
        ask "Choose"
        choice="${ANSWER,,}"
        case "$choice" in
            1) mode_single ;;
            2) mode_batch ;;
            3) mode_relabel ;;
            4) show_log ;;
            q|quit|exit) say "Goodbye."; exit 0 ;;
            *) err "Please type 1, 2, 3, 4 or q." ;;
        esac
    done
}

# --- start -------------------------------------------------------------------
if [ ! -f "$FLASHER" ]; then
    err "Cannot find flash-and-provision.sh next to this script ($FLASHER)."
    exit 1
fi
for tool in lsblk blockdev findmnt sha256sum od; do
    command -v "$tool" >/dev/null 2>&1 || { err "Required tool not found: $tool"; exit 1; }
done
init_log
head1 "Welcome"
say "This wizard flashes the golden S3 Gateway image onto SD cards and gives"
say "each card its own Gateway ID. Before you start:"
say "  - plug in your SD card reader,"
say "  - have the Gateway IDs from your batch sheet ready,"
say "  - never remove a card while it is being written."
say "You can stop at any time with Ctrl+C."
main_menu