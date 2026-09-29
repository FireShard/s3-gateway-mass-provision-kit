# S3 Zigbee Gateway — Mass Provisioning Kit

Turns the manual, one-Pi-at-a-time process in `docs/HANDOVER_PRODUCTION_TEAM_BUILD.md`
into: **build one golden image, flash it to every SD card, personalize each
card in seconds.**

## The core idea

Looking at `bootstrap-production-pi.sh` / `deploy-production.sh`, almost
everything they do is *identical for every gateway*: install packages,
create the `s3gw` account, build the venv, install the app code, lay down
systemd units, sudoers, log rotation, GPS ACLs. Only a handful of things are
genuinely per-unit:

| Per-unit (must vary)                              | Identical across the fleet (bake once) |
|-----------------------------------------------------|-----------------------------------------|
| `GATEWAY_ID` in `.env`                              | OS packages, Python venv, app code       |
| optionally: site `samplelist.csv` / `pygw_conf.py`  | `s3gw` account, `dialout` access         |
| optionally: site `required-<site>gw.zip` bundle     | systemd units, GPSUP override, sudoers   |
| the physical Zigbee USB dongle (hardware, per unit) | log retention, GPS ACL symlink           |
|                                                      | PostgreSQL *engine* (role/db/schema come later, see below) |

There's one wrinkle: `s3-gateway-dbup` (and the PostgreSQL role/database
creation in `bootstrap-production-pi.sh`) needs a **live** running
PostgreSQL and systemd — something a build-time chroot doesn't have. So
those steps can't be baked into the image; they have to run once the Pi
actually boots. That's the whole reason this kit has two phases instead of
one:

1. **Build phase** (`image/`) — an `rpi-image-gen` config + hook that
   produces one golden `.img` with everything static already installed and
   `GATEWAY_ID=UNPROVISIONED` as a sentinel.
2. **First-boot phase** (`image/firstboot/`) — a systemd oneshot service,
   already enabled in the image, that runs exactly once on real hardware:
   sets the real `GATEWAY_ID`, creates the Postgres role/db/schema if
   missing, installs any site-specific inventory, and runs the project's own
   `s3-gateway-dbup` to load it and start the service.

`host/flash-and-provision.sh` is what bridges the two: flash the same image
to every card, then drop a tiny `provision.env` (just `GATEWAY_ID=s3-gw-03`,
etc.) onto each card's boot partition before/after flashing. That file is
what phase 2 reads.

This mirrors the exact pattern the official `rpi-image-gen` getting-started
guide itself recommends for a fleet (one base config + per-identity
overrides) — see "Alternative" below for using that mechanism directly
instead of the first-boot step.

## Requirements

- A build host: Raspberry Pi 4/5 on 64-bit Raspberry Pi OS is the fully
  supported path; a recent Debian/Ubuntu **amd64** box works via
  `qemu-user-binfmt` (see "Cross-building on amd64" below).
- `rpi-image-gen` itself:
  ```
  git clone https://github.com/raspberrypi/rpi-image-gen.git
  cd rpi-image-gen
  sudo ./install_deps.sh
  ```
- Your existing `s3-zigbee-gateway.zip`, unpacked into
  `image/s3-zigbee-gateway/` (see the placeholder file there).
- An SD card reader (or several) on your provisioning workstation.

### Cross-building on amd64 (verified working)

`rpi-image-gen`'s dependency installer assumes a Debian/Ubuntu-family host
with `apt`. On anything else (Arch/CachyOS, etc.), run it inside a Debian
container instead (`distrobox create --image debian:trixie --additional-flags
"--privileged"`, or plain `podman run --privileged -it debian:trixie bash`).

Building an arm64 image on an amd64 host needs QEMU user-mode emulation:
```
sudo apt-get install -y qemu-user-binfmt   # some distros ship this instead of the older qemu-user-static
sudo systemctl restart systemd-binfmt.service
ls /proc/sys/fs/binfmt_misc/ | grep -i aarch64   # should list something, e.g. qemu-aarch64
```

**The actual build must run under `sudo`.** Running it as a plain user hits a
rootless-namespace bug where `tar` fails extracting setgid files
(`Cannot change ownership ... Invalid argument`) partway through. Real root
sidesteps it cleanly. One side effect: `sudo` resets `HOME`, so pass your SSH
key explicitly rather than relying on `$HOME` expansion in the config (see
the build command in step 2).

`sudo` also breaks `git describe` inside the `rpi-image-gen` checkout
("dubious ownership"), which makes every build on the same day compute an
identical output directory name and build on top of stale leftovers. Fix
once:
```
sudo git config --global --add safe.directory /path/to/rpi-image-gen
```

## 1. Prepare the project

```bash
unzip s3-zigbee-gateway.zip -d /tmp/x
rsync -a --exclude=.git/ /tmp/x/s3-zigbee-gateway/ image/s3-zigbee-gateway/
rm image/s3-zigbee-gateway/PUT_YOUR_REPO_HERE.txt
```

Edit `image/gateway-golden.yaml`:
- `device.layer` — set to `rpi3` (verified working on real hardware) or
  whatever else your fleet uses; run `./rpi-image-gen layer --list` in your
  `rpi-image-gen` checkout to see the full set for your version of the tool.
- `device.user1pass` — must satisfy the built-in complexity check (upper +
  lower + digit + one of `@$!%*?&`, 8+ chars) or the build fails validation.
- `locale.timezone` — defaults to `America/New_York` here (the base layer's
  own default is British English/`Europe/London`); adjust to your fleet's
  actual location.
- the `ssh.pubkey_user1` line (or delete the SSH block if you don't want the
  default `pi` user reachable over SSH — company policy per the handover doc
  still applies).
- If every gateway shares one production MQTT broker/credentials, uncomment
  and fill in the `MQTT_*` lines in `image/hooks/customize90-s3-gateway`
  (search for "production broker"). If brokers differ per site, leave them
  and pass overrides via `provision.env` instead (see step 3).

## 2. Build the golden image

```bash
cd rpi-image-gen
sudo ./rpi-image-gen build -S /path/to/s3-gateway-mass-provision-kit/image \
    -c /path/to/s3-gateway-mass-provision-kit/image/gateway-golden.yaml \
    -- IGconf_ssh_pubkey_user1="$(cat /home/youruser/.ssh/id_ed25519.pub)"
```

The hook (`customize90-s3-gateway`) does the equivalent of
`bootstrap-production-pi.sh` + the static parts of `deploy-production.sh`,
`install-runtime-hardening.sh`, `install-log-retention.sh` and
`setup-operator-gps-access.sh`, but against the target rootfs instead of a
live Pi. Build once; the resulting `.img` is what you flash to every card.

## 3. Flash and personalize each SD card

Every card gets the identical image plus a tiny `provision.env` (just
`GATEWAY_ID=...`) written to its boot partition. Site files — the node list
and gateway config for that gateway's site — are optional extras copied
alongside it. Start with the simplest form:

```bash
sudo host/flash-and-provision.sh \
    --image rpi-image-gen/work/image-.../*.img \
    --device /dev/sdb \
    --gateway-id s3-gw-03
```

With no site flags, the card keeps the `samplelist.csv` / `pygw_conf.py`
baked into the image, which are just the sample data shipped in the repo
(placeholder nodes like `FE01`/`FE02`). Any real site needs its own files —
see below.

### Site files: which flag do I use?

The script recognises exactly three files in a site folder; anything else is
ignored:

| File                    | Ends up on the gateway at                    |
|-------------------------|----------------------------------------------|
| `samplelist.csv`        | `/home/pi/S3Gateway/samplelist.csv`          |
| `pygw_conf.py`          | `/home/pi/S3Gateway/pygw_conf.py`            |
| `required-*gw.zip`      | `/opt/s3-gateway/app/pyserialgateway/`       |

All three are optional — supply only the ones that differ from the image's
defaults. On first boot they overwrite the baked-in copies *before*
`s3-gateway-dbup` runs, so the database is loaded from your site's list.

There are three ways to point the script at a site folder:

| Situation                              | Flags                                              | Where the files live         |
|----------------------------------------|----------------------------------------------------|------------------------------|
| One card, one folder (simplest)        | `--site-dir site-files/`                           | directly in `site-files/`    |
| One card, several sites to choose from | `--site-files-root site-files/ --site siteA`       | `site-files/siteA/`          |
| Many cards from a CSV                  | `--batch gateways.csv --site-files-root site-files/` | `site-files/<site>/` per CSV row |

**`--site-dir`** takes the folder *exactly as given* — no lookup, no
subfolders. Best when you only have one site, or want to point at a folder
anywhere on disk:

```bash
# site-files/samplelist.csv and site-files/pygw_conf.py sit directly in site-files/
sudo host/flash-and-provision.sh \
    --image rpi-2026-09-25.img \
    --device /dev/sda \
    --gateway-id s3-gw-99 \
    --site-dir site-files/
```

**`--site-files-root` + `--site`** treats the root as a library of sites and
picks one by name (`<root>/<site>`). Best when you manage several sites from
one workstation:

```bash
# site-files/siteA/samplelist.csv, site-files/siteA/pygw_conf.py, ...
#   site-files/siteB/samplelist.csv, ...
sudo host/flash-and-provision.sh \
    --image rpi-2026-09-25.img \
    --device /dev/sda \
    --gateway-id s3-gw-99 \
    --site-files-root site-files/ --site siteA
```

**`--batch`** reads a CSV (`gateway_id,site,...`; see
`host/gateways.csv.example`) and prompts you to swap cards between rows, using
each row's `site` column to pick `<root>/<site>`:

```bash
cp host/gateways.csv.example host/gateways.csv   # edit with real IDs/sites
sudo host/flash-and-provision.sh \
    --image rpi-image-gen/work/image-.../*.img \
    --device /dev/sdb \
    --batch host/gateways.csv \
    --site-files-root host/site-files/
```

Rules worth knowing:

- `--site-dir` wins if you pass it together with `--site-files-root`/`--site`.
- `--site-files-root` on its own (single card, no `--site`) does nothing — the
  script prints a warning rather than silently ignoring it.
- The script confirms what it copied. You should see one
  `==> Copied <file> from <folder>` line per file, followed by
  `==> Wrote provision.env (GATEWAY_ID=...)`. If the folder doesn't exist, or
  exists but contains none of the three recognised files, it prints a
  `WARNING` instead — treat a missing "Copied" line as a problem, not a
  success.
- To double-check a card afterwards (or a booted gateway):
  `ls /boot/firmware/s3-gateway-provision/` on the gateway, or mount the
  card's first partition and look in `s3-gateway-provision/`. After first boot,
  `journalctl -t s3-gateway-firstboot` shows `Installing site samplelist.csv
  into ...` for each file it applied.

Flashing itself is fast (`dd`/`rpi-imager --cli`, no rebuild) and the
per-card payload is a few hundred bytes plus your site files. That's the part
that scales: adding gateway #47 is "insert card, run one command", not "wait
for another full OS build".

## 4. First boot, per unit

Insert the card, connect the Zigbee USB gateway, power on. On this first
boot only, `s3-gateway-firstboot.service` runs before `s3-zigbee-gateway.service`
and:

1. Writes `GATEWAY_ID` (and any MQTT overrides) into `/opt/s3-gateway/app/.env`.
2. Installs any site `samplelist.csv` / `pygw_conf.py` / `required-*gw.zip`
   found alongside `provision.env`.
3. Creates the `s3gw` Postgres role, `serial-gateway-program` database and
   schema if they don't already exist.
4. Runs the project's own `s3-gateway-dbup` — same validation, backup,
   `DBUP_ONLY`, restart flow as a manual deployment.
5. Touches `/var/lib/s3-gateway/.provisioned` so it never runs again.
6. Logs a `validate-handover.sh` run to the journal as a QA trail
   (`journalctl -t s3-gateway-firstboot.validate`).

Verify per the existing acceptance checklist:

```bash
ssh pi@<new-hostname-or-ip>
sudo systemctl is-active s3-zigbee-gateway
sudo bash /opt/s3-gateway/app/scripts/validate-handover.sh
```

`s3-gateway-firstboot.service` sets the hostname to `GATEWAY_ID` too, so
`ssh pi@s3-gw-03.local` (mDNS) should resolve once it's on the network.

## Alternative: fully immutable per-unit images

If you'd rather have literally no first-boot step (e.g. units get
EMMC-flashed at a bench with no network, or you want every byte on the card
to be exactly reproducible from a single config file), skip the first-boot
service and instead build one full image per unit using `rpi-image-gen`'s
own layering, exactly like its getting-started guide does for per-location
images — see `image/gateway-site-example.yaml`:

```bash
cp image/gateway-site-example.yaml image/gateway-s3-gw-04.yaml
# edit env.GATEWAY_ID and device.hostname to s3-gw-04
./rpi-image-gen build -S image/ -c image/gateway-s3-gw-04.yaml
```

You'd then also move the Postgres/`s3-gateway-dbup` step into the build hook
(the README further up explains why that's fragile — you'd need to
temporarily start `postgresql` inside the build chroot, e.g. via
`pg_ctlcluster ... start`, run the SQL, then stop it again).

**Trade-off:** every gateway becomes a full separate image build. That's
fine for a handful of units, but doesn't scale the way "flash once,
provision in seconds" does once you're into dozens+. The first-boot
approach above is the recommended default; this is here for the cases where
an immutable per-unit artifact is actually a hard requirement.

## Fixes baked in from real hardware testing

Building and booting an actual unit surfaced several gaps this kit now
handles automatically — noted here so a future edit doesn't reintroduce
them:

- **Build must run as real root (`sudo`)**, not rootless — see "Cross-building
  on amd64" above.
- **Packages installed explicitly early in the hook**, not left to
  `rpi-image-gen`'s own `packages:` section. That mechanism does work, but
  its consuming hook (`builtin/hooks/customize20-packages`) runs *after*
  this project's own hook in the customize phase — too late for the venv
  creation a few lines later, which needs `python3.13-venv`/`postgresql`
  already present.
- **`wlan0` excluded from `systemd-networkd-wait-online`** via
  `RequiredForOnline=no`. Without it, every boot fails the network-online
  check (no WiFi profile is baked in, so `wlan0` never gets a carrier),
  which delays `s3-zigbee-gateway.service` since it orders
  `After=network-online.target`.
- **`PYSerialGateway/log`, `PYSerialGateway/errorlog`,
  `pyserialgateway/log`, `pyserialgateway/errorlog` symlinked** to the
  centralized operator log dir. `hardware_reset.py` opens a log file at a
  path relative to *itself*, not via `GATEWAY_LOG_DIR` — if these
  directories don't exist, the gateway service crashes on start with
  `[Errno 2] No such file or directory`.
- **Locale forced to US** (`locale:` in `gateway-golden.yaml`) — the base
  layer's own default is British keyboard/timezone, which silently made `|`
  and other symbols produce the wrong characters on a US keyboard.
- **Hostname step now logs its own outcome and falls back to `--transient`**
  if a static `hostnamectl set-hostname` is refused (e.g. root remounted
  read-only after an unclean shutdown) — previously failed silently with no
  journal trail at all.

## What's still manual, on purpose

- Plugging in the correct Zigbee USB gateway per physical unit.
- Deciding which physical Pi gets which `GATEWAY_ID` / site (that's the
  human judgment `gateways.csv` records).
- Anything the handover doc already marks as IoT/Development-only (source
  changes, DB schema changes, protocol work) — this kit only automates the
  Production Team's provisioning steps, it doesn't change who's allowed to
  touch what.

## Files in this kit

```
image/gateway-golden.yaml         rpi-image-gen config for the golden image
image/gateway-site-example.yaml   alternative: per-unit immutable image pattern
image/hooks/customize90-s3-gateway  build-time hook (app, venv, units, hardening)
image/firstboot/s3-gateway-firstboot.sh       first-boot provisioning script
image/firstboot/s3-gateway-firstboot.service  its systemd oneshot unit
image/s3-zigbee-gateway/          put your unzipped repo here
host/flash-and-provision.sh       flash + write provision.env per card
host/gateways.csv.example         batch mapping of gateway_id -> site
```
