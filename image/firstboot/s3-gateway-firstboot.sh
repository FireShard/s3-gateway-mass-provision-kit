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
#   <bootpart>/s3-gateway-provision/<node list>.csv  (optional site override; the
#                                                    name is localDBpath in pygw_conf.py,
#                                                    samplelist.csv by default)
#   <bootpart>/s3-gateway-provision/pygw_conf.py     (optional site override)
#   <bootpart>/s3-gateway-provision/required-*gw.zip (optional site bundle)
#
# host/flash-and-provision.sh (or the .ps1 / wizard) is what writes that folder
# onto each SD card after flashing the golden image. An image built with
# GATEWAY_ID set (image/gateway-site-example.yaml) carries the same provision.env
# as /etc/s3-gateway/provision.env, used when the card has none.
set -euo pipefail

MARKER=/var/lib/s3-gateway/.provisioned
TARGET_DIR=/opt/s3-gateway/app
ENV_FILE="$TARGET_DIR/.env"
DB_NAME=serial-gateway-program
SERVICE_USER=s3gw
OPERATOR_CONFIG=/etc/s3-gateway/operator.conf
LOG_TAG="s3-gateway-firstboot"

# Where provision.env may live, best first: the card, then the image itself.
PROVISION_DIR_CANDIDATES=(
    /boot/firmware/s3-gateway-provision
    /boot/s3-gateway-provision
    /etc/s3-gateway
)

# The only keys provision.env may set. Everything else in the file is ignored.
PROVISION_KEYS=(GATEWAY_ID MQTT_BROKER MQTT_PORT MQTT_USERNAME MQTT_PASSWORD MQTT_TOPIC_ROOT)

log() { echo "[$LOG_TAG] $*"; logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }

# --- reading provision.env ----------------------------------------------------
# provision.env is READ, not sourced: it comes from a removable card (and may have
# been edited on Windows), and this script runs as root. Only KEY=VALUE lines for
# the keys above are taken; blanks, comments, CR line endings and one pair of
# surrounding quotes are tolerated. Values land in the global PROVISION array.
declare -A PROVISION=()
read_provision_env() { # file
    local line key value k allowed
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        if [[ $value =~ ^\"(.*)\"$ ]] || [[ $value =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
        for k in "${PROVISION_KEYS[@]}"; do
            if [ "$k" = "$key" ]; then PROVISION[$key]="$value"; fi
        done
    done < "$1"
}

# --- writing the protected .env -----------------------------------------------
# set_env_value KEY VALUE  replaces KEY=... in the .env, or appends it.
set_env_value() {
    local key="$1" value="$2" escaped
    if grep -q "^${key}=" "$ENV_FILE"; then
        escaped="$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')"     # sed replacement specials
        sed -i "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

apply_env_overrides() {
    local key
    set_env_value GATEWAY_ID "${PROVISION[GATEWAY_ID]}"
    for key in "${PROVISION_KEYS[@]:1}"; do          # every key after GATEWAY_ID is an optional MQTT override
        if [ -n "${PROVISION[$key]:-}" ]; then set_env_value "$key" "${PROVISION[$key]}"; fi
    done
    chown root:"$SERVICE_USER" "$ENV_FILE"
    chmod 640 "$ENV_FILE"
}

# --- optional site-specific files ---------------------------------------------
# The node-list CSV is named by localDBpath in the pygw_conf.py that will be in
# use: the site's one if it was dropped on the card, else the image's own. The
# name is resolved with the app's own helper (scripts/lib/localdb.sh, shipped in
# the image with the source tree) so this script, s3-gateway-dbup, the gateway
# and the web admin can never disagree about what the file is called.
install_site_files() { # provision_dir
    local dir="$1" localdb_lib="$TARGET_DIR/scripts/lib/localdb.sh"
    local conf_in_use="$OPERATOR_DIR/pygw_conf.py" csv_name="" bundle

    if [ -f "$dir/pygw_conf.py" ]; then conf_in_use="$dir/pygw_conf.py"; fi
    if [ -f "$localdb_lib" ]; then
        # shellcheck disable=SC1090
        . "$localdb_lib"
        if ! csv_name="$(s3_node_list_name "$conf_in_use" 2>&1)"; then
            # Not fatal here: s3-gateway-dbup (below) refuses the same value with the
            # same message, after hostname and database are set up, so the unit still
            # leaves a usable log and a reachable hostname.
            log "WARNING: $csv_name"
            csv_name=""
        fi
    else
        log "WARNING: $localdb_lib missing - assuming the node list is samplelist.csv"
        csv_name="samplelist.csv"
    fi

    if [ -n "$csv_name" ] && [ -f "$dir/$csv_name" ]; then
        log "Installing site node list $csv_name into $OPERATOR_DIR"
        install -o "$OPERATOR_USER" -g "$OPERATOR_USER" -m 644 "$dir/$csv_name" "$OPERATOR_DIR/$csv_name"
    elif [ -n "$csv_name" ] && [ -f "$dir/pygw_conf.py" ]; then
        log "WARNING: pygw_conf.py points at '$csv_name' but it is not in $dir - using whatever is already in $OPERATOR_DIR"
    fi

    if [ -f "$dir/pygw_conf.py" ]; then
        log "Installing site pygw_conf.py into $OPERATOR_DIR"
        install -o "$OPERATOR_USER" -g "$OPERATOR_USER" -m 644 "$dir/pygw_conf.py" "$OPERATOR_DIR/pygw_conf.py"
    fi

    for bundle in "$dir"/required-*gw.zip; do
        [ -e "$bundle" ] || continue
        log "Installing Zigbee bundle $(basename "$bundle")"
        install -o root -g "$SERVICE_USER" -m 640 "$bundle" "$TARGET_DIR/pyserialgateway/$(basename "$bundle")"
    done
}

# --- hostname personalization (helps SSH/inventory on the LAN) -----------------
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
    local name="$1" write_error
    local valid_re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'

    if ! [[ $name =~ $valid_re ]]; then
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
        printf 'preserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-s3-gateway-preserve-hostname.cfg \
            || log "WARNING: could not write cloud-init preserve_hostname override"
    fi

    if ! write_error="$({ printf '%s\n' "$name" > /etc/hostname; } 2>&1)"; then
        log "WARNING: could not write /etc/hostname: $write_error - leaving hostname unchanged"
        return 0
    fi

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

# --- idempotent PostgreSQL role/database/schema init ---------------------------
# Same logic as scripts/bootstrap-production-pi.sh's postgres block, just
# moved here because it needs a live postgresql, not a build-time chroot.
as_postgres() { runuser -u postgres -- "$@"; }

ensure_database() {
    log "Ensuring PostgreSQL role/database/schema exist"
    if ! as_postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${SERVICE_USER}'" | grep -q '^1$'; then
        as_postgres createuser "$SERVICE_USER"
    fi
    if ! as_postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q '^1$'; then
        as_postgres createdb -O "$SERVICE_USER" "$DB_NAME"
    fi
    if as_postgres psql -d "$DB_NAME" -tAc "SELECT to_regclass('public.node_database') IS NOT NULL" | grep -q '^t$'; then
        return 0
    fi
    as_postgres psql -d "$DB_NAME" <<SQL
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
}

# --- load the (now-installed) site inventory -----------------------------------
# Reuses the project's own, already-tested wrapper rather than reimplementing
# its validation/backup/DBUP_ONLY/restart logic here. S3_DBUP_SKIP_RESTART=1
# tells dbup to skip its own `systemctl start` - s3-zigbee-gateway.service is
# After=/Before=-ordered against this very unit, so calling `systemctl start`
# on it from inside our own still-running ExecStart would deadlock; systemd
# starts it automatically the moment this script (and this unit) finishes.
# (dbup must honor S3_DBUP_SKIP_RESTART - the image build refuses to proceed
# if the bundled copy does not.) Never add a synchronous `systemctl start/
# stop/restart s3-zigbee-gateway` to this script; use --no-block if ever needed.
run_dbup() {
    log "Running s3-gateway-dbup"
    if S3_DBUP_SKIP_RESTART=1 /usr/local/sbin/s3-gateway-dbup; then
        log "s3-gateway-dbup: PASS"
    else
        log "ERROR: s3-gateway-dbup failed - leaving unit unmarked so it retries next boot"
        exit 1
    fi
}

# Optional QA trail: run the project's own read-only acceptance check and
# log the result (does not fail this unit on WARN/FAIL - it's informational).
# It checks that the gateway is ACTIVE, which is impossible while this unit is
# still running (the gateway is ordered After= us), so run it shortly after we
# exit, as a detached transient unit, instead of inline.
schedule_handover_check() {
    [ -x "$TARGET_DIR/scripts/validate-handover.sh" ] || return 0
    log "Scheduling validate-handover.sh (60s after first-boot) for the QA trail"
    systemd-run --no-block --quiet --on-active=60 --unit=s3-gateway-firstboot-validate \
        /bin/bash -c "bash '$TARGET_DIR/scripts/validate-handover.sh' 2>&1 | logger -t '$LOG_TAG.validate'" \
        || log "WARNING: could not schedule validate-handover.sh"
}

find_provision_dir() { # prints the first candidate that holds a provision.env
    local dir
    for dir in "${PROVISION_DIR_CANDIDATES[@]}"; do
        if [ -f "$dir/provision.env" ]; then printf '%s' "$dir"; return 0; fi
    done
    return 1
}

main() {
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

    local provision_dir
    if ! provision_dir="$(find_provision_dir)"; then
        log "ERROR: no provision.env found in: ${PROVISION_DIR_CANDIDATES[*]}"
        log "This SD card was flashed from the golden image but never got a"
        log "GATEWAY_ID written to its boot partition. Run"
        log "host/flash-and-provision.sh against this card, then reboot."
        exit 1
    fi

    read_provision_env "$provision_dir/provision.env"
    local gateway_id="${PROVISION[GATEWAY_ID]:-}"
    if [ -z "$gateway_id" ]; then
        log "ERROR: $provision_dir/provision.env did not set GATEWAY_ID"
        exit 1
    fi
    log "Provisioning as GATEWAY_ID=$gateway_id (source: $provision_dir)"

    apply_env_overrides
    install_site_files "$provision_dir"

    # Optional ZIGBEE_SERIAL= / RCP_SERIAL= (combined S3 + S5 image): lets radio-bind name the
    # radios without probing. radio-bind parses the file itself and never overrides a role it has
    # already identified. A problem here is logged, not fatal.
    if [ -x /usr/local/sbin/radio-bind ]; then
        /usr/local/sbin/radio-bind seed "$provision_dir/provision.env" --apply 2>&1 \
            | while IFS= read -r line; do log "radio-bind: $line"; done \
            || log "WARNING: radio-bind seeding reported a problem; radios will be probed instead"
    fi
    set_gateway_hostname "$gateway_id"
    ensure_database
    run_dbup

    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 750 /var/lib/s3-gateway
    touch "$MARKER"
    log "Provisioning complete for $gateway_id"
    schedule_handover_check
}

# Skipped when the file is sourced (which is how the functions above get tested).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
