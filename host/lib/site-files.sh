#!/bin/bash
# Shared helpers for host/flash-and-provision.sh and host/flash-and-provision-wizard.sh.
# Source this file; it is not meant to be run.
#
#   Gateway IDs     GATEWAY_ID_RE, is_valid_gateway_id
#   Radio serials   is_valid_radio_serial, is_weak_radio_serial, radio_serial_problems, provision_env_text
#   Tailscale       tailscale_authkey_problem, mask_tailscale_authkey, tailscale_in_image, tailscale_on_card
#   Text clean-up   trim, clean_field
#   Site folders    site_csv_name, site_problem, node_list_problems, site_inspect
#   Batch CSV       read_gateway_csv  ->  B_ID[] / B_SITE[] / B_ZB[] / B_RCP[]
#   Help text       print_script_usage
#
# The callers must define  err "message"  (print an error); a plain fallback is
# provided here for scripts that do not.

[ -z "${_S3_SITE_LIB_LOADED:-}" ] || return 0
_S3_SITE_LIB_LOADED=1

# The Gateway ID becomes the Pi's hostname, so it follows hostname rules. This is
# the same rule image/firstboot/s3-gateway-firstboot.sh applies.
GATEWAY_ID_RE='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'

# Name of the folder on the card's boot partition that first boot reads.
PROVISION_DIR_NAME="s3-gateway-provision"

# Node list used when a site folder has no pygw_conf.py (the image's own one).
DEFAULT_NODE_LIST="samplelist.csv"

if ! declare -F err >/dev/null; then
    err() { printf 'ERROR: %s\n' "$*" >&2; }
fi

is_valid_gateway_id() { [[ $1 =~ $GATEWAY_ID_RE ]]; }

# --- radio serials (combined S3 + S5 image) ----------------------------------------
# The combined image has two CP210x radios, told apart by USB serial number (radio-bind). A card may
# carry both serials in provision.env (ZIGBEE_SERIAL / RCP_SERIAL) so a new unit never has to probe.
# Both are optional. The rules are radio-bind's own, so a serial refused here would be refused there.
RADIO_SERIAL_RE='^[A-Za-z0-9_.:-]{1,64}$'

is_valid_radio_serial() { [[ $1 =~ $RADIO_SERIAL_RE ]]; }

# Serials that cannot identify one radio: too short, one repeated character, or a known factory default
# (many CP210x boards ship with 0001).
is_weak_radio_serial() {
    local s="${1,,}"
    [ "${#s}" -lt 8 ] && return 0
    [ -z "${s//"${s:0:1}"/}" ] && return 0
    case "$s" in 0123456789|1234567890|0123456789abcdef|abcdef0123456789) return 0 ;; esac
    return 1
}

# radio_serial_problems ZIGBEE RCP  prints one line per problem (nothing if both are fine or empty).
radio_serial_problems() {
    local zb="$1" rcp="$2" which value
    for which in zigbee rcp; do
        if [ "$which" = zigbee ]; then value="$zb"; else value="$rcp"; fi
        [ -n "$value" ] || continue
        if ! is_valid_radio_serial "$value"; then
            echo "the $which serial '$value' is not a USB serial number (letters, digits and _ . : - only, up to 64 characters)"
        elif is_weak_radio_serial "$value"; then
            echo "the $which serial '$value' is too generic to identify one radio (many boards share it)"
        fi
    done
    if [ -n "$zb" ] && [ "${zb,,}" = "${rcp,,}" ]; then
        echo "the Zigbee and RCP serials are the same ('$zb'): they are two different radios"
    fi
}

# provision_env_text GATEWAY_ID [ZIGBEE] [RCP] [TAILSCALE_AUTHKEY]  the exact content of provision.env.
# LF line endings only.
provision_env_text() {
    printf 'GATEWAY_ID=%s\n' "$1"
    if [ -n "${2:-}" ]; then printf 'ZIGBEE_SERIAL=%s\n' "$2"; fi
    if [ -n "${3:-}" ]; then printf 'RCP_SERIAL=%s\n' "$3"; fi
    if [ -n "${4:-}" ]; then printf 'TAILSCALE_AUTHKEY=%s\n' "$4"; fi
}

# --- Tailscale (images built with the gateway-tailscale first-boot join) ---------------
# A card whose provision.env has a TAILSCALE_AUTHKEY= line joins the gateway tailnet at first boot:
# /usr/local/sbin/gateway-tailscale-join (gateway-tailscale repo) reads the key, joins, then removes the
# line from the card. The flashers only offer a key for an image that really has Tailscale AND that join
# service inside it, found by looking into the image's root filesystem (read-only, nothing is mounted).

# A Tailscale auth key is tskey-auth- followed by letters, digits, '-' and '_'. Nothing else is accepted:
# API access tokens (tskey-api-) and OAuth client secrets (tskey-client-) are not auth keys, and a value
# with spaces, quotes or shell characters has no business in provision.env.
TAILSCALE_AUTHKEY_RE='^tskey-auth-[A-Za-z0-9_-]{8,200}$'

# tailscale_authkey_problem KEY  prints why KEY cannot be used (one line); prints nothing when it is fine.
tailscale_authkey_problem() {
    local k="${1-}"
    if [ -z "$k" ]; then
        echo "the key is empty"
    elif [[ $k == tskey-api-* ]]; then
        echo "that is a Tailscale API access token, not an auth key (create one under Settings > Keys > Generate auth key)"
    elif [[ $k == tskey-client-* ]]; then
        echo "that is an OAuth client secret, not an auth key (create one under Settings > Keys > Generate auth key)"
    elif [[ $k != tskey-auth-* ]]; then
        echo "an auth key starts with tskey-auth- (create one under Settings > Keys > Generate auth key)"
    elif [ "${#k}" -lt 19 ]; then
        echo "the key is too short to be a Tailscale auth key"
    elif ! [[ $k =~ $TAILSCALE_AUTHKEY_RE ]]; then
        echo "the key has characters an auth key never contains (only letters, digits, '-' and '_' are allowed; no spaces, quotes or '?' options)"
    fi
}

# mask_tailscale_authkey KEY  what is safe to print: the prefix and the last four characters.
mask_tailscale_authkey() {
    local k="${1-}"
    if [ "${#k}" -gt 16 ]; then printf 'tskey-auth-...%s' "${k: -4}"; else printf '(hidden)'; fi
}

# mbr_partition_start FILE N  byte offset of MBR partition N (1-4) in FILE (an image or a block device);
# fails when the slot is empty or FILE has no MBR.
mbr_partition_start() {
    local file="$1" n="$2" base type lba
    base=$((446 + (n - 1) * 16))
    type="$(od -An -tu1 -j $((base + 4)) -N1 "$file" 2>/dev/null | tr -d ' \n')"
    lba="$(od -An -tu4 --endian=little -j $((base + 8)) -N4 "$file" 2>/dev/null | tr -d ' \n')"
    { [ -n "$type" ] && [ "$type" != 0 ] && [ -n "$lba" ] && [ "$lba" -gt 0 ]; } || return 1
    echo $((lba * 512))
}

# ext4_has_path TARGET PATH  looks PATH up in the ext2/3/4 filesystem at TARGET without mounting it.
# TARGET is a partition device, or FILE?offset=BYTES for a partition inside an image file.
# Returns 0 if PATH exists, 1 if it does not, 2 if TARGET could not be read as such a filesystem (or
# debugfs from e2fsprogs is missing).
ext4_has_path() {
    local out
    command -v debugfs >/dev/null 2>&1 || return 2
    out="$(debugfs -R "stat $2" "$1" 2>&1)" || true      # debugfs reports problems in its output, not its exit status
    if grep -q '^Inode:' <<<"$out"; then return 0; fi
    if grep -q 'File not found by ext2_lookup' <<<"$out"; then return 1; fi
    return 2
}

# tailscale_state_of_fs TARGET  if TARGET is a Linux root filesystem (it has /etc/os-release), prints
# yes (Tailscale and its first-boot join service are both there) or no, and returns 0. Returns 1 for
# anything else (the boot partition, a data partition, unreadable).
tailscale_state_of_fs() {
    local p rc
    ext4_has_path "$1" /etc/os-release || return 1
    for p in /usr/sbin/tailscaled /usr/local/sbin/gateway-tailscale-join; do
        rc=0; ext4_has_path "$1" "$p" || rc=$?
        if [ "$rc" -ne 0 ]; then echo no; return 0; fi
    done
    echo yes
}

# tailscale_in_image IMAGE  prints yes, no or unknown (the root filesystem could not be read: no MBR,
# no debugfs, an unusual layout). IMAGE is a plain .img file.
tailscale_in_image() {
    local n off st
    for n in 1 2 3 4; do
        off="$(mbr_partition_start "$1" "$n")" || continue
        if st="$(tailscale_state_of_fs "$1?offset=$off")"; then echo "$st"; return 0; fi
    done
    echo unknown
}

# tailscale_on_card DEVICE  the same for a card that is already flashed (partition devices, read-only).
tailscale_on_card() {
    local dev="$1" n p st
    for n in 2 3 4 1; do
        for p in "${dev}${n}" "${dev}p${n}"; do
            [ -b "$p" ] || continue
            if st="$(tailscale_state_of_fs "$p")"; then echo "$st"; return 0; fi
        done
    done
    echo unknown
}

# --- text clean-up -------------------------------------------------------------
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Clean a value typed, dragged into the terminal, or read from a spreadsheet:
# surrounding blanks and quotes go, "\ " becomes a plain space.
clean_field() {
    local s
    s="$(trim "$1")"
    s="${s#\'}"; s="${s%\'}"; s="${s#\"}"; s="${s%\"}"
    s="${s//\\ / }"
    printf '%s' "$s"
}

# --- site folders --------------------------------------------------------------
# The node-list CSV is not always called samplelist.csv: the site's pygw_conf.py
# names it (localDBpath = '...'), and s3-gateway-dbup - which runs on first boot
# and refuses to continue on a bad value - applies a strict rule. This mirrors
# it (scripts/s3-gateway-dbup, read_local_db_name):
#   - the LAST top-level `localDBpath = '<name>'` line wins, like Python
#   - <name> is a plain file name: [A-Za-z0-9_.-], 1-60 characters, then .csv
# No pygw_conf.py in the folder -> the image's own config is used -> samplelist.csv.
#
# site_csv_name DIR  prints the file name and returns 0; for an unusable setting
# it prints the reason (no "ERROR:" prefix) and returns 1.
site_csv_name() {
    local conf="$1/pygw_conf.py" line name
    local name_re='^[A-Za-z0-9_.-]{1,60}\.csv$'
    local assignment_re="^localDBpath[[:space:]]*=[[:space:]]*(['\"])([^'\"\\\\]*)\\1[[:space:]]*(#.*)?$"

    if [ ! -f "$conf" ]; then
        printf '%s' "$DEFAULT_NODE_LIST"
        return 0
    fi
    line="$(tr -d '\r' < "$conf" | grep -E '^localDBpath[[:space:]]*=' | tail -n 1 || true)"
    if [ -z "$line" ]; then
        printf '%s' "localDBpath is not set in pygw_conf.py (s3-gateway-dbup refuses a pygw_conf.py without it)."
        return 1
    fi
    if ! [[ $line =~ $assignment_re ]]; then
        printf '%s' "localDBpath in pygw_conf.py must be a plain quoted string such as 'samplelist.csv'."
        return 1
    fi
    name="${BASH_REMATCH[2]}"
    if ! [[ $name =~ $name_re ]]; then
        printf '%s' "localDBpath '$name' in pygw_conf.py must be a plain file name ending in .csv (letters, digits, . _ - only, at most 60 characters before .csv, no folders)."
        return 1
    fi
    printf '%s' "$name"
}

# The image only ships samplelist.csv. If pygw_conf.py names another file and the
# site folder does not contain it, first boot would stop at s3-gateway-dbup.
_missing_node_list_message() { # name
    printf "pygw_conf.py names the node list '%s' but that file is not in this folder (the image only ships %s, so first boot would stop at s3-gateway-dbup)." \
        "$1" "$DEFAULT_NODE_LIST"
}

# site_problem DIR  prints why first boot would fail with this folder and returns 1;
# returns 0 (silently) when the folder is fine. Checked BEFORE a card is written:
# a card that fails here would retry s3-gateway-dbup on every boot until someone
# fixed it by hand.
site_problem() {
    local d="$1" name
    name="$(site_csv_name "$d")" || { printf '%s' "$name"; return 1; }
    if [ -f "$d/pygw_conf.py" ] && [ "$name" != "$DEFAULT_NODE_LIST" ] && [ ! -f "$d/$name" ]; then
        _missing_node_list_message "$name"
        return 1
    fi
    return 0
}

# node_list_problems FILE NAME  prints one line per duplicate in the node list (nothing when it is clean).
# NAME is only used in the messages. s3-gateway-dbup runs on the Pi at first boot and stops on a
# duplicate node ID or pole ID (scripts/s3-gateway-dbup), after the card is already written; this finds
# the same mistakes before. Line numbers are the file's own (the header is line 1, as in a text editor
# or Excel). Checked:
#   - the same node ID twice            dbup stops: "duplicate node ID"
#   - the same pole_node twice          dbup stops: "duplicate pole ID"
#   - 2a01 and 2A01 (same ID, other letter case)
#                                       dbup lets it through but the node is registered twice
# Values are trimmed like dbup trims them. An empty node/pole cell is not a duplicate (dbup reports
# an incomplete row for it). The header must be exactly pole_node,node,pan_id,channel, as dbup demands;
# without it the columns cannot be told apart, so that is reported instead. A UTF-16 file is skipped here:
# check_text_encoding gives the proper message for it. At most 10 lines are printed, then a count.
node_list_problems() {
    local file="$1" name="${2:-$1}" sig
    [ -f "$file" ] || return 0
    sig="$(head -c 2 "$file" | od -An -tx1 | tr -d ' \n')"
    if [ "$sig" = "fffe" ] || [ "$sig" = "feff" ]; then return 0; fi

    LC_ALL=C awk -v name="$name" -v limit=10 '
    function split_csv(s,    n, i, c, cur, inq, start) {
        n = 0; cur = ""; inq = 0; start = 1
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (inq) {
                if (c == "\"") {
                    if (substr(s, i + 1, 1) == "\"") { cur = cur "\""; i++ }
                    else inq = 0
                } else cur = cur c
            } else if (c == "\"" && start) { inq = 1; start = 0 }
            else if (c == ",") { F[++n] = cur; cur = ""; start = 1 }
            else { cur = cur c; start = 0 }
        }
        F[++n] = cur
        return n
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function report(msg) { found++; if (found <= limit) print name " line " NR ": " msg }
    { line = $0; sub(/\r$/, "", line) }
    NR == 1 && substr(line, 1, 3) == "\357\273\277" { line = substr(line, 4) }
    line ~ /^[ \t,]*$/ { next }
    !header_done {
        header_done = 1
        n = split_csv(line); joined = F[1]
        for (i = 2; i <= n; i++) joined = joined "," F[i]
        if (joined != "pole_node,node,pan_id,channel") {
            print name " line " NR ": the header must be exactly pole_node,node,pan_id,channel (s3-gateway-dbup refuses any other header, so duplicates cannot be checked)."
            header_bad = 1; exit
        }
        next
    }
    {
        split_csv(line)
        pole = trim(F[1]); node = trim(F[2])
        if (node != "") {
            if (node in seen_node) {
                report("node ID " node " is already used on line " seen_node[node] " (s3-gateway-dbup stops on a duplicate node ID).")
            } else if (tolower(node) in fold_node) {
                report("node ID " node " is the same ID as " fold_text[tolower(node)] " on line " fold_node[tolower(node)] " in a different letter case; s3-gateway-dbup lets it through but the node would be registered twice.")
            } else {
                seen_node[node] = NR; fold_node[tolower(node)] = NR; fold_text[tolower(node)] = node
            }
        }
        if (pole != "") {
            if (pole in seen_pole) report("pole ID " pole " is already used on line " seen_pole[pole] " (s3-gateway-dbup stops on a duplicate pole ID).")
            else seen_pole[pole] = NR
        }
    }
    END {
        if (!header_bad && found > limit) print name ": ... and " (found - limit) " more duplicate(s) not listed."
    }' "$file"
}

# site_inspect DIR  fills SITE_FOUND[] (files that will be installed), SITE_MISSING[]
# (expected files that are absent; the image default is kept) and SITE_ERRORS[]
# (things that would break first boot, including duplicate nodes in the node list:
# see node_list_problems). Returns 1 if the folder cannot be used:
# it has errors, or none of the expected files.
site_inspect() {
    local d="$1" csv zip problem
    local -a zips=()
    SITE_FOUND=(); SITE_MISSING=(); SITE_ERRORS=()

    if csv="$(site_csv_name "$d")"; then
        if [ -f "$d/$csv" ]; then
            SITE_FOUND+=("$csv")
            while IFS= read -r problem; do
                [ -n "$problem" ] || continue
                SITE_ERRORS+=("$problem")
            done < <(node_list_problems "$d/$csv" "$csv")
        else
            SITE_MISSING+=("$csv")
            if [ -f "$d/pygw_conf.py" ] && [ "$csv" != "$DEFAULT_NODE_LIST" ]; then
                SITE_ERRORS+=("$(_missing_node_list_message "$csv")")
            fi
        fi
    else
        SITE_ERRORS+=("$csv")      # on failure site_csv_name printed the reason
    fi

    if [ -f "$d/pygw_conf.py" ]; then SITE_FOUND+=("pygw_conf.py"); else SITE_MISSING+=("pygw_conf.py"); fi

    zips=("$d"/required-*gw.zip)
    if [ -e "${zips[0]:-}" ]; then
        for zip in "${zips[@]}"; do SITE_FOUND+=("$(basename "$zip")"); done
    else
        SITE_MISSING+=("required-*gw.zip")
    fi

    [ "${#SITE_ERRORS[@]}" -eq 0 ] && [ "${#SITE_FOUND[@]}" -gt 0 ]
}

join_by_comma() { local IFS=,; printf '%s' "$*" | sed 's/,/, /g'; }

# --- batch CSV -----------------------------------------------------------------
# read_gateway_csv FILE  fills B_ID[], B_SITE[], B_ZB[] and B_RCP[] (same index = same card).
# The first real line is the header and must contain "gateway_id" (optional "site", and for the combined
# S3 + S5 image "zigbee_serial" and "rcp_serial"; a serial must not appear on two cards).
# Blank lines, "#" comment lines, a UTF-8 BOM, Excel/Windows line endings, quotes
# and stray blanks are all fine. Every problem is reported with err; returns 1 if
# there was any. Rows with a bad ID are still listed in B_ID so row numbers match
# the file, so callers must not use the arrays when this fails.
read_gateway_csv() {
    local file="$1" line id site zb rcp lower seen=" " problem key
    local header_done=0 id_col=-1 site_col=-1 zb_col=-1 rcp_col=-1 row=0 bad=0 i
    local -a cols=()
    local -A serial_row=()
    B_ID=(); B_SITE=(); B_ZB=(); B_RCP=()

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [ "$header_done" = 0 ]; then line="${line#$'\xef\xbb\xbf'}"; fi
        [[ $line =~ ^[[:space:],]*(#.*)?$ ]] && continue      # blank, comment, or an empty Excel row (",,,")

        IFS=, read -r -a cols <<< "$line"
        for i in "${!cols[@]}"; do cols[i]="$(clean_field "${cols[i]}")"; done

        if [ "$header_done" = 0 ]; then
            for i in "${!cols[@]}"; do
                case "${cols[i],,}" in
                    gateway_id) id_col="$i" ;;
                    site)       site_col="$i" ;;
                    zigbee_serial) zb_col="$i" ;;
                    rcp_serial)    rcp_col="$i" ;;
                esac
            done
            if [ "$id_col" -lt 0 ]; then
                err "The first line of the CSV must be a header containing 'gateway_id' (for example: gateway_id,site,notes)."
                return 1
            fi
            header_done=1
            continue
        fi

        row=$((row + 1))
        id="${cols[id_col]:-}"
        site=""
        if [ "$site_col" -ge 0 ]; then site="${cols[site_col]:-}"; fi
        zb=""; rcp=""
        if [ "$zb_col" -ge 0 ];  then zb="${cols[zb_col]:-}"; fi
        if [ "$rcp_col" -ge 0 ]; then rcp="${cols[rcp_col]:-}"; fi

        lower="${id,,}"
        if ! is_valid_gateway_id "$id"; then
            err "Row $row: '$id' is not a valid Gateway ID."; bad=1
        elif [[ $seen == *" $lower "* ]]; then
            err "Row $row: Gateway ID '$id' appears twice in the CSV."; bad=1
        fi
        seen="$seen$lower "

        while IFS= read -r problem; do
            [ -n "$problem" ] || continue
            err "Row $row ($id): $problem."; bad=1
        done < <(radio_serial_problems "$zb" "$rcp")
        for key in "$zb" "$rcp"; do
            [ -n "$key" ] || continue
            if [ "${serial_row[${key,,}]:-$row}" != "$row" ]; then      # same row: already reported as "the same serial"
                err "Row $row ($id): serial '$key' is already used on row ${serial_row[${key,,}]}: each radio has its own."; bad=1
            else
                serial_row[${key,,}]="$row"
            fi
        done

        B_ID+=("$id"); B_SITE+=("$site"); B_ZB+=("$zb"); B_RCP+=("$rcp")
    done < "$file"

    if [ "$header_done" = 0 ]; then err "The CSV file is empty."; return 1; fi
    if [ "${#B_ID[@]}" -eq 0 ]; then err "The CSV has a header but no cards."; return 1; fi
    [ "$bad" = 0 ]
}

# --- help text -----------------------------------------------------------------
# print_script_usage FILE  prints the leading comment block of a script (the
# header that documents it), without the "# " prefix.
print_script_usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$1"
}
