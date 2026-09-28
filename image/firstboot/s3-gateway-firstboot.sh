#!/bin/bash
# Runs once, on the first real boot of a flashed SD card, as root.
#
# Everything this script does needs a genuinely LIVE system (a running
# PostgreSQL server, a running systemd) which is exactly what was NOT
# available at image-build time - that's why this is a first-boot service
# instead of another build hook.
#
# It looks for a small drop-in folder on the boot partition:
#   <bootpart>/s3-gateway-provision/provision.env   (required: GATEWAY_ID=...)
#   <bootpart>/s3-gateway-provision/samplelist.csv   (optional site override)
#   <bootpart>/s3-gateway-provision/pygw_conf.py     (optional site override)
#   <bootpart>/s3-gateway-provision/required-*gw.zip (optional site bundle)
#
# host/flash-and-provision.sh is what writes that folder onto each SD card
# after flashing the golden image.
set -euo pipefail

MARKER=/var/lib/s3-gateway/.provisioned
SERVICE_NAME=s3-zigbee-gateway
TARGET_DIR=/opt/s3-gateway/app
DB_NAME=serial-gateway-program
SERVICE_USER=s3gw
OPERATOR_CONFIG=/etc/s3-gateway/operator.conf
LOG_TAG="s3-gateway-firstboot"

log() { echo "[$LOG_TAG] $*"; logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }

if [ -f "$MARKER" ]; then
    log "Already provisioned ($MARKER exists). Nothing to do."
    exit 0
fi

if [ -f "$OPERATOR_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$OPERATOR_CONFIG"
fi
OPERATOR_USER="${S3_OPERATOR_USER:-pi}"
OPERATOR_DIR="${S3_OPERATOR_DIR:-/home/$OPERATOR_USER/S3Gateway}"

# --- locate the provisioning drop dropped on the boot partition ------------
CANDIDATES=(
    /boot/firmware/s3-gateway-provision
    /boot/s3-gateway-provision
)
PROVISION_DIR=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c/provision.env" ]; then
        PROVISION_DIR="$c"
        break
    fi
done

if [ -z "$PROVISION_DIR" ]; then
    log "ERROR: no provision.env found in: ${CANDIDATES[*]}"
    log "This SD card was flashed from the golden image but never got a"
    log "GATEWAY_ID written to its boot partition. Run"
    log "host/flash-and-provision.sh against this card, then reboot."
    exit 1
fi

# shellcheck disable=SC1090
. "$PROVISION_DIR/provision.env"

if [ -z "${GATEWAY_ID:-}" ]; then
    log "ERROR: $PROVISION_DIR/provision.env did not set GATEWAY_ID"
    exit 1
fi

log "Provisioning as GATEWAY_ID=$GATEWAY_ID (source: $PROVISION_DIR)"

# --- apply GATEWAY_ID (and any optional overrides) into the protected .env -
ENV_FILE="$TARGET_DIR/.env"
set_env_value() {
    key="$1"; value="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}
set_env_value GATEWAY_ID "$GATEWAY_ID"
[ -n "${MQTT_BROKER:-}" ] && set_env_value MQTT_BROKER "$MQTT_BROKER"
[ -n "${MQTT_PORT:-}" ] && set_env_value MQTT_PORT "$MQTT_PORT"
[ -n "${MQTT_USERNAME:-}" ] && set_env_value MQTT_USERNAME "$MQTT_USERNAME"
[ -n "${MQTT_PASSWORD:-}" ] && set_env_value MQTT_PASSWORD "$MQTT_PASSWORD"
[ -n "${MQTT_TOPIC_ROOT:-}" ] && set_env_value MQTT_TOPIC_ROOT "$MQTT_TOPIC_ROOT"
chown root:"$SERVICE_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"

# --- optional site-specific files ------------------------------------------
if [ -f "$PROVISION_DIR/samplelist.csv" ]; then
    log "Installing site samplelist.csv into $OPERATOR_DIR"
    install -o "$OPERATOR_USER" -g "$OPERATOR_USER" -m 644 \
        "$PROVISION_DIR/samplelist.csv" "$OPERATOR_DIR/samplelist.csv"
fi
if [ -f "$PROVISION_DIR/pygw_conf.py" ]; then
    log "Installing site pygw_conf.py into $OPERATOR_DIR"
    install -o "$OPERATOR_USER" -g "$OPERATOR_USER" -m 644 \
        "$PROVISION_DIR/pygw_conf.py" "$OPERATOR_DIR/pygw_conf.py"
fi
for bundle in "$PROVISION_DIR"/required-*gw.zip; do
    [ -e "$bundle" ] || continue
    log "Installing Zigbee bundle $(basename "$bundle")"
    install -o root -g "$SERVICE_USER" -m 640 "$bundle" \
        "$TARGET_DIR/pyserialgateway/$(basename "$bundle")"
done

# --- hostname personalization (helps SSH/inventory on the LAN) --------------
# Deliberately NOT done with `hostnamectl set-hostname`. systemd-hostnamed
# runs sandboxed with a stripped-down capability set, and on this image its
# write to /etc/hostname is refused with a *privilege* error, which it
# reports as "Not allowed to update /etc/hostname" (a genuinely read-only
# filesystem would say "is in a read-only filesystem" instead - and
# everything else this script writes to disk succeeds, so root is writable).
# This script runs as full root, so write the static name directly and set
# the running kernel hostname to match. hostnamectl's --transient fallback
# is not enough on its own: a transient name is lost on reboot, and this
# unit never runs again once $MARKER exists.
set_gateway_hostname() {
    local name="$1"
    local valid_re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'

    if ! [[ "$name" =~ $valid_re ]]; then
        log "WARNING: GATEWAY_ID '$name' is not a valid hostname (letters, digits and '-', max 63, no leading/trailing '-') - leaving hostname unchanged"
        return 0
    fi

    # Best-effort: clear an immutable flag if one was ever set on the file.
    chattr -i /etc/hostname 2>/dev/null || true

    # Only relevant if cloud-init happens to be installed (it is NOT part of
    # this image's build config): its update_hostname module would otherwise
    # rewrite /etc/hostname on the next boot. No-op when /etc/cloud is absent.
    if [ -d /etc/cloud ]; then
        install -d -m 755 /etc/cloud/cloud.cfg.d
        printf 'preserve_hostname: true\n' \
            > /etc/cloud/cloud.cfg.d/99-s3-gateway-preserve-hostname.cfg \
            || log "WARNING: could not write cloud-init preserve_hostname override"
    fi

    if ! printf '%s\n' "$name" > /etc/hostname 2>/tmp/hostname.err; then
        log "WARNING: could not write /etc/hostname: $(cat /tmp/hostname.err 2>/dev/null) - leaving hostname unchanged"
        rm -f /tmp/hostname.err
        return 0
    fi
    rm -f /tmp/hostname.err

    # Running (kernel) hostname; no dependency on the `hostname` binary or D-Bus.
    printf '%s' "$name" > /proc/sys/kernel/hostname 2>/dev/null \
        || hostnamectl set-hostname --transient "$name" 2>/dev/null \
        || log "WARNING: could not set the running hostname - it will apply on next boot"

    # Keep the 127.0.1.1 alias in step so `sudo` and local lookups don't stall.
    if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
        sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${name}/" /etc/hosts \
            || log "WARNING: could not update /etc/hosts"
    else
        printf '127.0.1.1\t%s\n' "$name" >> /etc/hosts \
            || log "WARNING: could not update /etc/hosts"
    fi

    log "Hostname set to $name (static /etc/hostname: $(cat /etc/hostname 2>/dev/null); running: $(cat /proc/sys/kernel/hostname 2>/dev/null))"
}
set_gateway_hostname "$GATEWAY_ID"

# --- idempotent PostgreSQL role/database/schema init -----------------------
# Same logic as scripts/bootstrap-production-pi.sh's postgres block, just
# moved here because it needs a live postgresql, not a build-time chroot.
log "Ensuring PostgreSQL role/database/schema exist"
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${SERVICE_USER}'" | grep -q '^1$'; then
    runuser -u postgres -- createuser "$SERVICE_USER"
fi
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q '^1$'; then
    runuser -u postgres -- createdb -O "$SERVICE_USER" "$DB_NAME"
fi
if ! runuser -u postgres -- psql -d "$DB_NAME" -tAc "SELECT to_regclass('public.node_database') IS NOT NULL" | grep -q '^t$'; then
    runuser -u postgres -- psql -d "$DB_NAME" <<SQL
CREATE TABLE node_database (
    id SERIAL PRIMARY KEY,
    pole_node TEXT,
    node TEXT NOT NULL,
    pan_id TEXT,
    channel TEXT,
    latitude TEXT,
    longitude TEXT,
    description TEXT
);
CREATE INDEX idx_node_database_node ON node_database (node);
CREATE INDEX idx_node_database_pan_channel ON node_database (pan_id, channel);

CREATE TABLE filter_time_py (
    id SERIAL PRIMARY KEY,
    node TEXT NOT NULL,
    ack TEXT NOT NULL,
    dtime TIMESTAMP,
    msgid TEXT,
    oo_msgid TEXT,
    dec_count INTEGER DEFAULT 0,
    rollover_count INTEGER DEFAULT 0,
    miss_count INTEGER DEFAULT 0,
    override_flag BOOLEAN,
    lamp_status BOOLEAN
);
CREATE INDEX idx_filter_time_py_node_ack ON filter_time_py (node, ack);

ALTER TABLE node_database OWNER TO ${SERVICE_USER};
ALTER TABLE filter_time_py OWNER TO ${SERVICE_USER};
ALTER SEQUENCE node_database_id_seq OWNER TO ${SERVICE_USER};
ALTER SEQUENCE filter_time_py_id_seq OWNER TO ${SERVICE_USER};
SQL
fi

# --- load the (now-installed) site inventory and start the service ---------
# Reuses the project's own, already-tested wrapper rather than reimplementing
# its validation/backup/DBUP_ONLY/restart logic here. S3_DBUP_SKIP_RESTART=1
# tells dbup to skip its own `systemctl start` - s3-zigbee-gateway.service is
# After=/Before=-ordered against this very unit, so calling `systemctl start`
# on it from inside our own still-running ExecStart would deadlock; systemd
# starts it automatically the moment this script (and this unit) finishes.
log "Running s3-gateway-dbup"
if S3_DBUP_SKIP_RESTART=1 /usr/local/sbin/s3-gateway-dbup; then
    log "s3-gateway-dbup: PASS"
else
    log "ERROR: s3-gateway-dbup failed - leaving unit unmarked so it retries next boot"
    exit 1
fi

install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 750 /var/lib/s3-gateway
touch "$MARKER"
log "Provisioning complete for $GATEWAY_ID"

# Optional QA trail: run the project's own read-only acceptance check and
# log the result (does not fail this unit on WARN/FAIL - it's informational).
if [ -x "$TARGET_DIR/scripts/validate-handover.sh" ]; then
    log "Running validate-handover.sh for the QA trail"
    bash "$TARGET_DIR/scripts/validate-handover.sh" 2>&1 | logger -t "$LOG_TAG.validate" || true
fi