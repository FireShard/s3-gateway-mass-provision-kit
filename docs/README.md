# S3 Zigbee Gateway — Mass Provisioning

This project makes it easy to create many Raspberry Pi gateways from one **golden image**.

Instead of installing and configuring every Pi manually:

1. Build one image.
2. Flash the same image to every SD card.
3. Give each gateway its own `GATEWAY_ID`.
4. Optionally copy site-specific files.
5. Boot the Pi and let the first-boot script finish the setup.

The result is much faster provisioning for a fleet of gateways.

---

## How it works

There are two phases.

### 1. Build the golden image

The `image/` directory contains the configuration and build hook used to create the image.

The image contains everything that is the same on every gateway:

- Raspberry Pi OS
- Required packages
- Python virtual environment
- S3 Gateway application
- `s3gw` user
- Systemd services
- Sudo rules
- Log rotation
- GPS permissions
- PostgreSQL software
- Default/sample gateway files

The image uses:

```text
GATEWAY_ID=UNPROVISIONED
```

This is only a temporary value.

### 2. First boot

When a newly flashed Pi starts for the first time, `s3-gateway-firstboot.service`:

1. Sets the real `GATEWAY_ID`.
2. Sets the hostname to the gateway ID.
3. Applies optional MQTT settings.
4. Copies any site-specific files.
5. Creates the PostgreSQL role/database/schema if needed.
6. Runs `s3-gateway-dbup`.
7. Starts/validates the gateway.
8. Marks provisioning as complete so it does not run again.

The gateway ID and optional site files come from the SD card's provisioning area.

---

# Requirements

You need:

- A Raspberry Pi 4/5 with 64-bit Raspberry Pi OS, **or** an amd64 Debian/Ubuntu build machine.
- `rpi-image-gen`.
- Your `s3-zigbee-gateway.zip`.
- An SD card reader.

## Install `rpi-image-gen`

```bash
git clone https://github.com/raspberrypi/rpi-image-gen.git
cd rpi-image-gen
sudo ./install_deps.sh
```

---

# Building on an amd64 PC

If you build an ARM64 Raspberry Pi image on an amd64 machine, install QEMU:

```bash
sudo apt-get install -y qemu-user-binfmt
sudo systemctl restart systemd-binfmt.service
```

Check that ARM64 emulation is available:

```bash
ls /proc/sys/fs/binfmt_misc/ | grep -i aarch64
```

You should see something such as:

```text
qemu-aarch64
```

### Important: build with `sudo`

The image build must be run as root.

Otherwise, the build can fail while extracting files.

Because `sudo` changes the environment, provide the SSH public key explicitly when building.

You may also need to tell Git that the `rpi-image-gen` directory is trusted:

```bash
sudo git config --global --add safe.directory /path/to/rpi-image-gen
```

---

# 1. Prepare the project

Unpack the gateway application into:

```text
image/s3-zigbee-gateway/
```

For example:

```bash
unzip s3-zigbee-gateway.zip -d /tmp/x
rsync -a --exclude=.git/ /tmp/x/s3-zigbee-gateway/ image/s3-zigbee-gateway/
rm image/s3-zigbee-gateway/PUT_YOUR_REPO_HERE.txt
```

---

# 2. Configure the golden image

Edit:

```text
image/gateway-golden.yaml
```

Check these settings:

### Raspberry Pi model

Set the correct layer for your hardware.

For example:

```text
device.layer: rpi3
```

To see the available layers:

```bash
./rpi-image-gen layer --list
```

### User password

The configured password must contain:

- Uppercase letter
- Lowercase letter
- Number
- One of `@$!%*?&`
- At least 8 characters

### Timezone

Set the timezone to the location where the gateways will be used.

### SSH key

Set the SSH public key if the default `pi` user should be accessible through SSH.

### MQTT

If every gateway uses the same MQTT broker, configure the `MQTT_*` values in:

```text
image/hooks/customize90-s3-gateway
```

If different sites use different brokers, leave these values for provisioning time and put the overrides in `provision.env`.

---

# 3. Build the golden image

From the `rpi-image-gen` directory:

```bash
sudo ./rpi-image-gen build   -S /path/to/s3-gateway-mass-provision-kit/image   -c /path/to/s3-gateway-mass-provision-kit/image/gateway-golden.yaml   -- IGconf_ssh_pubkey_user1="$(cat /home/youruser/.ssh/id_ed25519.pub)"
```

The result is a Raspberry Pi `.img` file.

**Build this image only once.**

The same image can then be used for every gateway.

---

# 4. Flash and personalize a gateway

Use:

```bash
sudo host/flash-and-provision.sh   --image rpi-image-gen/work/image-.../*.img   --device /dev/sdb   --gateway-id s3-gw-03
```

Change:

- `--image` to your generated image.
- `--device` to the SD card device.
- `--gateway-id` to the ID assigned to that physical gateway.

For example:

```text
s3-gw-01
s3-gw-02
s3-gw-03
```

The script:

1. Flashes the image.
2. Creates the provisioning information.
3. Writes the gateway ID to the card.

Every card uses the same image. Only its provisioning data changes.

---

# Site-specific files

A gateway can also receive site-specific configuration files.

The script recognizes these three files:

| File | Installed location |
|---|---|
| `samplelist.csv` | `/home/pi/S3Gateway/samplelist.csv` |
| `pygw_conf.py` | `/home/pi/S3Gateway/pygw_conf.py` |
| `required-*gw.zip` | `/opt/s3-gateway/app/pyserialgateway/` |

All three are optional.

If provided, they replace the default files in the image before the database setup runs.

## Option A — One site folder

Put the files directly in a folder:

```text
site-files/
├── samplelist.csv
├── pygw_conf.py
└── required-site-gw.zip
```

Then run:

```bash
sudo host/flash-and-provision.sh   --image rpi-2026-09-25.img   --device /dev/sda   --gateway-id s3-gw-99   --site-dir site-files/
```

Use this when you are provisioning one gateway or one site at a time.

---

## Option B — Multiple sites

Organize the files like this:

```text
site-files/
├── siteA/
│   ├── samplelist.csv
│   └── pygw_conf.py
└── siteB/
    ├── samplelist.csv
    └── pygw_conf.py
```

Then choose the site:

```bash
sudo host/flash-and-provision.sh   --image rpi-2026-09-25.img   --device /dev/sda   --gateway-id s3-gw-99   --site-files-root site-files/   --site siteA
```

---

## Option C — Provision many gateways from CSV

Create the CSV:

```bash
cp host/gateways.csv.example host/gateways.csv
```

Edit it with the gateway IDs and sites.

Then run:

```bash
sudo host/flash-and-provision.sh   --image rpi-image-gen/work/image-.../*.img   --device /dev/sdb   --batch host/gateways.csv   --site-files-root host/site-files/
```

The script will ask you to change the SD card between gateways.

Each CSV row determines the gateway ID and site files.

---

# Provisioning rules

A few important rules:

- `--site-dir` takes priority over `--site-files-root` and `--site`.
- `--site-files-root` by itself does not select a site.
- The script prints a `Copied` message for every site file it installs.
- If no site files are found, the script prints a warning.
- A missing `Copied` message should be treated as a problem.

To check the provisioning files on a card:

```bash
ls /boot/firmware/s3-gateway-provision/
```

After the Pi boots, check the first-boot log:

```bash
journalctl -t s3-gateway-firstboot
```

---

# 5. First boot

Put the SD card into the Raspberry Pi.

Connect the correct Zigbee USB gateway and power on the Pi.

On the first boot, the provisioning service runs automatically.

It performs the remaining setup and then creates:

```text
/var/lib/s3-gateway/.provisioned
```

This file prevents the first-boot process from running again.

---

# 6. Verify the gateway

SSH into the gateway:

```bash
ssh pi@<hostname-or-ip>
```

Check that the service is running:

```bash
sudo systemctl is-active s3-zigbee-gateway
```

Run the project's validation script:

```bash
sudo bash /opt/s3-gateway/app/scripts/validate-handover.sh
```

The hostname is normally the same as the `GATEWAY_ID`.

For example:

```bash
ssh pi@s3-gw-03.local
```

---

# What changes between gateways?

Only a few things should normally be different.

| Per gateway | Shared |
|---|---|
| `GATEWAY_ID` | OS |
| Site `samplelist.csv` | Python environment |
| Site `pygw_conf.py` | Application |
| Site `required-*gw.zip` | Systemd services |
| MQTT overrides, if required | `s3gw` account |
| Physical Zigbee USB dongle | PostgreSQL software |
| | Log configuration |
| | GPS permissions |

The physical Zigbee dongle is hardware, so each gateway must have its own correct device.

---

# What is still manual?

These tasks are intentionally left to the operator:

- Connect the correct Zigbee USB gateway.
- Decide which physical Pi receives which `GATEWAY_ID`.
- Decide which site belongs to each gateway.
- Perform development-only work such as application changes, database schema changes, or protocol changes.

This tool is for **production provisioning**, not development.

---

# Alternative: one image per gateway

It is also possible to build a separate immutable image for every gateway.

Example:

```bash
cp image/gateway-site-example.yaml image/gateway-s3-gw-04.yaml
```

Edit the gateway ID and hostname, then build:

```bash
./rpi-image-gen build   -S image/   -c image/gateway-s3-gw-04.yaml
```

This gives each gateway its own image.

However, it means rebuilding an image for every gateway.

For a large number of gateways, the recommended approach is:

```text
One golden image
       ↓
Flash every SD card
       ↓
Add GATEWAY_ID / site files
       ↓
First boot
       ↓
Gateway ready
```

---

# Important fixes already included

The provisioning kit already handles several issues found during real hardware testing:

- The image build runs as root.
- Required packages are installed early enough for the Python environment.
- Wi-Fi does not block `network-online.target`.
- Required gateway log directories are created.
- Gateway logs are linked to the central operator log directory.
- Locale settings are explicitly configured.
- Hostname changes are logged and have a fallback method.

These fixes should not be removed without testing on real hardware.

---

# Project files

```text
image/
├── gateway-golden.yaml
├── gateway-site-example.yaml
├── hooks/
│   └── customize90-s3-gateway
├── firstboot/
│   ├── s3-gateway-firstboot.sh
│   └── s3-gateway-firstboot.service
└── s3-zigbee-gateway/

host/
├── flash-and-provision.sh
└── gateways.csv.example
```

### Main files

| File | Purpose |
|---|---|
| `gateway-golden.yaml` | Golden image configuration |
| `customize90-s3-gateway` | Installs and configures the gateway during image creation |
| `s3-gateway-firstboot.sh` | Finishes gateway setup on first boot |
| `s3-gateway-firstboot.service` | Runs the first-boot script |
| `flash-and-provision.sh` | Flashes and personalizes an SD card |
| `gateways.csv.example` | Example batch provisioning list |

---

# Quick reference

For a normal gateway, the process is simply:

### 1. Build the image once

```bash
sudo ./rpi-image-gen build ...
```

### 2. Flash a card

```bash
sudo host/flash-and-provision.sh   --image <image.img>   --device <sd-card>   --gateway-id s3-gw-01
```

### 3. Add site files if needed

```bash
--site-dir <site-folder>
```

### 4. Boot the Pi

The first-boot service completes the setup automatically.

### 5. Verify

```bash
sudo systemctl is-active s3-zigbee-gateway
sudo bash /opt/s3-gateway/app/scripts/validate-handover.sh
```

That's the complete provisioning flow.
