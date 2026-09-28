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
set -euo pipefail

IMAGE=""
DEVICE=""
GATEWAY_ID=""
SITE_DIR=""
SITE=""
BATCH_CSV=""
SITE_FILES_ROOT=""
DO_FLASH=1

usage() { sed -n '2,27p' "$0"; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        --gateway-id) GATEWAY_ID="$2"; shift 2 ;;
        --site-dir) SITE_DIR="$2"; shift 2 ;;
        --site) SITE="$2"; shift 2 ;;
        --batch) BATCH_CSV="$2"; shift 2 ;;
        --site-files-root) SITE_FILES_ROOT="$2"; shift 2 ;;
        --no-flash) DO_FLASH=0; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo/root (writes to a block device)." >&2; exit 1; }
[ -n "$DEVICE" ] || { echo "ERROR: --device is required." >&2; exit 1; }
[ -b "$DEVICE" ] || { echo "ERROR: not a block device: $DEVICE" >&2; exit 1; }
if [ "$DO_FLASH" -eq 1 ]; then
    [ -n "$IMAGE" ] && [ -f "$IMAGE" ] || { echo "ERROR: --image PATH is required unless --no-flash." >&2; exit 1; }
fi
if [ -z "$BATCH_CSV" ]; then
    [ -n "$GATEWAY_ID" ] || { echo "ERROR: --gateway-id or --batch CSV is required." >&2; exit 1; }
    # Single-card mode: --site-files-root only does anything when paired with
    # --site (it picks $SITE_FILES_ROOT/$SITE). Compute that here so it's not
    # silently a no-op the way it was before - and warn if it's still unusable.
    if [ -z "$SITE_DIR" ] && [ -n "$SITE_FILES_ROOT" ] && [ -n "$SITE" ]; then
        SITE_DIR="$SITE_FILES_ROOT/$SITE"
    fi
    if [ -n "$SITE_FILES_ROOT" ] && [ -z "$SITE_DIR" ]; then
        echo "WARNING: --site-files-root has no effect here without --site (single-card mode) or --batch. No site files will be copied." >&2
    fi
fi

confirm_device() {
    echo
    echo "About to write to: $DEVICE"
    lsblk -o NAME,SIZE,MODEL,MOUNTPOINT "$DEVICE" || true
    echo
    read -r -p "Type the device path again to confirm ($DEVICE): " confirm
    [ "$confirm" = "$DEVICE" ] || { echo "Confirmation did not match. Aborting." >&2; exit 1; }
}

flash_image() {
    echo "==> Flashing $IMAGE to $DEVICE"
    umount "${DEVICE}"?* 2>/dev/null || true
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

boot_partition_of() {
    # Works for both /dev/sdX -> /dev/sdX1 and /dev/mmcblk0 -> /dev/mmcblk0p1
    local dev="$1"
    if [ -b "${dev}1" ]; then
        echo "${dev}1"
    elif [ -b "${dev}p1" ]; then
        echo "${dev}p1"
    else
        echo ""
    fi
}

provision_card() {
    local gw_id="$1" site_dir="$2"
    local bootpart mnt
    bootpart="$(boot_partition_of "$DEVICE")"
    [ -n "$bootpart" ] || { echo "ERROR: could not find boot partition on $DEVICE" >&2; exit 1; }

    mnt="$(mktemp -d)"
    mount "$bootpart" "$mnt"
    trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' RETURN

    local pdir="$mnt/s3-gateway-provision"
    mkdir -p "$pdir"
    printf 'GATEWAY_ID=%s\n' "$gw_id" > "$pdir/provision.env"

    if [ -n "$site_dir" ] && [ -d "$site_dir" ]; then
        [ -f "$site_dir/samplelist.csv" ] && cp "$site_dir/samplelist.csv" "$pdir/"
        [ -f "$site_dir/pygw_conf.py" ] && cp "$site_dir/pygw_conf.py" "$pdir/"
        cp "$site_dir"/required-*gw.zip "$pdir/" 2>/dev/null || true
    fi

    sync
    umount "$mnt"
    rmdir "$mnt"
    trap - RETURN
    echo "==> Wrote provision.env (GATEWAY_ID=$gw_id) to $bootpart"
}

do_one_card() {
    local gw_id="$1" site_dir="$2"
    confirm_device
    [ "$DO_FLASH" -eq 1 ] && flash_image
    provision_card "$gw_id" "$site_dir"
    echo "==> Done: $DEVICE -> $gw_id"
}

if [ -n "$BATCH_CSV" ]; then
    [ -f "$BATCH_CSV" ] || { echo "ERROR: batch CSV not found: $BATCH_CSV" >&2; exit 1; }
    tail -n +2 "$BATCH_CSV" | while IFS=, read -r gw_id site _rest; do
        [ -n "$gw_id" ] || continue
        site_dir=""
        [ -n "$SITE_FILES_ROOT" ] && [ -n "$site" ] && site_dir="$SITE_FILES_ROOT/$site"
        echo
        echo "############################################################"
        echo "# Next card: gateway_id=$gw_id  site=${site:-<none>}"
        echo "# Insert the SD card as $DEVICE, then press Enter."
        echo "############################################################"
        read -r -p "> " _
        do_one_card "$gw_id" "$site_dir"
    done
else
    do_one_card "$GATEWAY_ID" "$SITE_DIR"
fi
