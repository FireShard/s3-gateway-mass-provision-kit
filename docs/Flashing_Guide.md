# Flashing S3 Gateway SD Cards - User Guide

This guide shows how to prepare SD cards for the S3 gateways, on **Windows** or **Linux**.

For each card, the tools do two things:

1. **Flash** - copy the "golden" gateway image onto the SD card.
2. **Provision** - give that card its own **Gateway ID** (for example `s3-gw-03`) and, optionally, the **site files** for the place it will be installed.

When the gateway boots for the first time, it reads this information from the card and sets itself up. A card made on Windows and a card made on Linux end up identical.

> **Run this on your own computer (the provisioning PC), never on a gateway.**

---

## 1. What you need

| Item | Notes |
|---|---|
| The **golden image** | A plain `.img` file (for example `rpi3-s3-gw.img`). If you downloaded a compressed file (`.xz`, `.zip`, `.gz`), extract it first. |
| An **SD card reader** | Plugged into your computer. |
| **SD cards** | At least as big as the image. |
| **Gateway IDs** | One unique ID per card, from your batch sheet. |
| **Site files** (optional) | One folder per site, containing the files described in section 6. |
| **Administrator rights** | Windows: you click "Yes" on a prompt. Linux: your `sudo` password. |

**Optional but recommended:** put a checksum file next to the image, named `<image name>.sha256` (for example `rpi3-s3-gw.img.sha256`). The wizard then checks the image is not damaged before it writes anything.

### Folder layout

Keep the files together in the kit folder:

```
kit/
  rpi3-s3-gw.img                 <- the golden image (can also be in Downloads or Desktop)
  host/
    flash-and-provision.bat      <- Windows: double-click this
    flash-and-provision.ps1      <- Windows script (keep next to the .bat)
    flash-and-provision-wizard.sh   <- Linux: the guided wizard
    flash-and-provision.sh       <- Linux: the command-line flasher
    gateways.csv                 <- your batch list (optional)
    site-files/
      siteA/                     <- one folder per site
      siteB/
    flash-log.csv                <- created automatically (record of every card)
```

---

## 2. Quick start

### Windows

1. Plug in the SD card reader.
2. **Double-click `flash-and-provision.bat`.**
3. Click **Yes** when Windows asks for permission.
4. Follow the questions on screen.

### Linux

1. Plug in the SD card reader.
2. Open a terminal in the kit folder and run:
   ```
   ./host/flash-and-provision-wizard.sh
   ```
3. Enter your password if asked, then follow the questions on screen.

That is all most people ever need. The rest of this guide explains what the wizard asks, and the advanced command-line options.

---

## 3. The wizard (same on Windows and Linux)

The wizard asks one question at a time. Press **Enter** to accept a suggested answer shown in `[brackets]`. You can stop at any time with **Ctrl+C**.

### Main menu

| Choice | What it does |
|---|---|
| **1) Flash SD cards, one at a time** | The normal choice. Flashes a card, then asks if you want to do another. |
| **2) Flash a batch from a CSV list** | Flashes many cards from a prepared list, one after another. |
| **3) Change the Gateway ID on a card that has never been booted** | Rewrites only the ID and site files. Does **not** re-flash the image. |
| **4) Show what has been flashed** | Shows the last 20 entries of the log. |
| **q) Quit** | Exits the wizard. |

### Flashing one card (option 1)

1. **Image** - the wizard looks for a `.img` file in the kit folder, Downloads and Desktop. If it finds one, it asks "Use it?". Otherwise, type the path or drag the file into the window. It checks that the file is really a disk image, is not compressed, and matches its `.sha256` checksum if there is one.
2. **Gateway ID** - type the ID for this card. It suggests the next number after the last one you used (`s3-gw-03` then `s3-gw-04`). See the ID rules in section 7. If the ID was already used, it warns you.
3. **Site** - choose the site folder for this card, or `0` for "no site files" (the gateway then uses the defaults built into the image). It shows which files will be installed and which are missing.
4. **SD card** - insert the card. The wizard detects it and shows its size and name. It only lists real SD cards / USB readers. It will never offer:
   - your computer's own system disk,
   - the disk the image or the kit is stored on,
   - a disk larger than 256 GB,
   - a card too small for the image.
5. **Summary** - it shows a "Please check" box (image, card, Gateway ID, site files). Confirm with `y`.
6. **Final safety check** - you must type the **disk number** (Windows, for example `2`) or **device path** (Linux, for example `/dev/sdb`) again. This is your last chance to cancel.
7. **Writing** - a progress bar shows. **Never remove the card while it is writing.**
8. **Done** - when you see `DONE - card for s3-gw-03 is ready`, wait for the reader light to stop blinking, take the card out and **label it with its Gateway ID**.

The wizard then waits for you to remove the card before the next one, so the same card cannot be flashed twice by mistake.

> **Windows only:** after flashing, Windows may say "You need to format the disk before you can use it". Click **Cancel**. Formatting would erase the gateway image.

### Batch from a CSV (option 2)

Use this when you have many cards to make. First create a file such as `gateways.csv`. The first line must be a header:

```
gateway_id,site,notes
s3-gw-01,siteA,Maintainence
s3-gw-02,siteA,Broken Pole
s3-gw-03,siteB,
s3-gw-04,,no site files
```

| Column | Meaning |
|---|---|
| `gateway_id` | **Required.** The unique ID for that card. |
| `site` | Optional. Name of a folder inside `site-files`. Leave empty for no site files. |
| `notes` | Optional. Anything you like. It is ignored. |

Rules: lines starting with `#` and blank lines are ignored. You can save the file from Excel.

What the wizard does:

1. Checks the **whole list first**: bad IDs, the same ID twice, and site folders that do not exist are all reported before any card is touched.
2. Shows the list and marks cards that were already flashed. You can choose to **skip those** (useful if a batch was interrupted).
3. For each card, it says "Card 2 of 4: s3-gw-02", waits for you to insert a card, then asks: **Enter** = start, **s** = skip this card, **q** = stop the batch.
4. Shows a summary at the end: how many were flashed, failed and skipped.

### Change an ID without re-flashing (option 3)

Use this only for a **spare card that has never been put in a gateway** and needs a different ID. It is much faster because the image is not rewritten.

> A gateway that has **already booted** keeps its old ID. To change the ID of a card that has been used, flash it again with option 1.

### The log (`flash-log.csv`)

Every card is recorded in `flash-log.csv` (in the `host` folder on Linux, next to the script on Windows). It stores the time, who ran it, the Gateway ID, site, result (`FLASHED`, `RELABELED` or `INCOMPLETE`), image name and card model. It is what allows the "already flashed" warnings. You can open it in Excel.

If a card shows **INCOMPLETE**, it failed or was cancelled. **Do not use that card** until it has been flashed again successfully.


---

## 4. After flashing: install the card and start the gateway

Flashing and provisioning prepare the SD card. The **next step is to put the card into the Raspberry Pi and let the gateway finish its setup on first boot**.

### Step 1 — Label and install the SD card

Before leaving the provisioning PC:

1. Make sure the wizard says:
   ```text
   DONE - card for <Gateway ID> is ready
   ```
2. Wait for the SD card reader light to stop blinking.
3. Remove the SD card.
4. **Label the card with its Gateway ID.**
5. Insert the card into the Raspberry Pi assigned to that Gateway ID.
6. Connect the correct Zigbee USB gateway.
7. Connect the network.
8. Power on the Raspberry Pi.

> The Gateway ID is also used as the gateway hostname.

For example:

```text
Gateway ID: s3-gw-03
Hostname:   s3-gw-03
```

### Step 2 — Let first boot finish

Do not immediately interrupt the Pi after power-on.

On the first boot, the gateway reads the provisioning information written by the flashing wizard and performs the remaining setup.

It:

1. Sets the `GATEWAY_ID`.
2. Sets the hostname to the Gateway ID.
3. Applies any MQTT settings supplied during provisioning.
4. Installs the site files, if any were provided.
5. Creates the PostgreSQL role/database/schema if needed.
6. Runs `s3-gateway-dbup`.
7. Starts the gateway service.
8. Marks the Pi as provisioned so the first-boot setup does not run again.

Allow the Pi enough time to complete this first boot before starting the verification steps.

### Step 3 — Find the gateway on the network

The hostname should be the Gateway ID.

For example:

```text
s3-gw-03
```

Try:

```bash
ssh pi@s3-gw-03
```


If `.local` does not resolve, find the Pi's IP address from your network/DHCP list and connect using:

```bash
ssh pi@<gateway-ip>
```

A new gateway gets its address by DHCP from its fibre/SIM router. If this gateway needs a fixed address, set it once you are logged in:

```bash
sudo nmcli con mod Wired ipv4.method manual ipv4.addresses <ip>/<prefix> ipv4.gateway <router-ip> ipv4.dns "<router-ip> 8.8.8.8"
sudo nmcli con up Wired
```

Your SSH session drops when the address changes; reconnect to the new address. Full details are in the *Networking (NetworkManager)* section of `README.md`.

### Step 4 — launch the gateway service and check that the gateway service is running

After logging in:

```bash
sudo s3-gateway-dbup
```
The expected result is:

```text
DBUP: PASS

Starting production gateway...
```
The command should end and sned back the user to the terminal console after outputing `Starting production gateway...`

Then:

```bash
sudo systemctl is-active s3-zigbee-gateway
```

The expected result is:

```text
active
```

If it is active, the main gateway service is running.

### Step 5 — Run the gateway validation

Run the project's validation script:

```bash
sudo bash /opt/s3-gateway/app/scripts/validate-handover.sh
```

Review the output for any failures.

This is the main post-installation check before handing the gateway over for use.

### Step 6 — Check the first-boot log if something went wrong

If the service is not running or the configuration is not correct, check the first-boot log:

```bash
journalctl -t s3-gateway-firstboot
```

For more detail about the validation performed during first boot:

```bash
journalctl -t s3-gateway-firstboot.validate
```

You can also check the gateway service:

```bash
sudo systemctl status s3-zigbee-gateway
```

### Step 7 — Confirm site files, if used

If you selected a site during flashing, the first-boot process should have installed the supplied files.

Check:

```bash
ls -l /home/pi/S3Gateway/samplelist.csv
ls -l /home/pi/S3Gateway/pygw_conf.py
```

If a `required-*gw.zip` package was supplied, check:

```bash
ls -l /opt/s3-gateway/app/pyserialgateway/
```

The first-boot log should also show which site files were installed:

```bash
journalctl -t s3-gateway-firstboot
```

### Step 8 — Final handover check

A gateway is ready for handover when:

- The correct Gateway ID is configured.
- The hostname matches the Gateway ID.
- The gateway can be reached over the network.
- `s3-zigbee-gateway` is **active**.
- `validate-handover.sh` completes successfully.
- The correct site files are present, if applicable.
- The correct Zigbee USB gateway is connected.

Record the completed Gateway ID in your batch/provisioning records.

---

## Quick post-flashing checklist

Use this checklist for every gateway:

```text
[ ] SD card labelled with Gateway ID
[ ] SD card inserted into the correct Raspberry Pi
[ ] Correct Zigbee USB gateway connected
[ ] Network connected
[ ] Pi powered on
[ ] First-boot setup completed
[ ] SSH connection works
[ ] Hostname matches Gateway ID
[ ] s3-zigbee-gateway is active
[ ] validate-handover.sh passes
[ ] Site files verified (if applicable)
[ ] Gateway recorded as completed
```

> **Important:** A card being successfully flashed does not by itself mean the gateway is ready for use. Always complete the first-boot and verification steps above.

---

## 5. Wizard options

You normally do not need these.

### Windows (`flash-and-provision.ps1`, or the `.bat`)

| Option | What it does |
|---|---|
| `-Image PATH` | Use this golden image instead of searching for one. |
| `-SiteFilesRoot DIR` | The folder that holds one sub-folder per site. Default: `site-files` next to the script. |
| `-KeepLineEndings` | Copy the site files exactly as they are. By default, Windows-style line endings (CRLF) and a hidden UTF-8 marker are converted to Linux style, because the gateway runs Linux. Leave this off unless you know you need it. |
| `-AllowNonRemovable` | Also show disks that are not USB/SD. **Dangerous** - see section 8. |

### Linux (`flash-and-provision-wizard.sh`)

| Option | What it does |
|---|---|
| `--image PATH` | Use this golden image instead of searching for one. |
| `--site-files-root DIR` | The folder that holds one sub-folder per site. Default: `host/site-files`. |
| `-h`, `--help` | Show the built-in help. |

Example (Linux): `./host/flash-and-provision-wizard.sh --image ~/Downloads/rpi3-s3-gw.img`

---

## 5. Command-line mode (advanced, no questions)

Use this for scripting or when you already know exactly what you want. If you give **any** card option (Windows: `-GatewayId`, `-Batch`, `-DiskNumber`, `-SiteDir`, `-Site`, `-NoFlash`, `-ListDisks`; Linux: the flasher script below), it skips the wizard and does exactly what you typed. You still have to re-type the disk number/device to confirm before anything is written.

### Windows

Open **PowerShell as Administrator** in the `host` folder.

| Option | What it does |
|---|---|
| `-Image PATH` | The golden `.img` file to write. Not needed with `-NoFlash`. |
| `-DiskNumber N` | The Windows disk number of the SD card. If left out, you pick from a list. |
| `-GatewayId ID` | The ID for this card, for example `s3-gw-03`. |
| `-SiteDir PATH` | A folder with this gateway's site files, used exactly as given. |
| `-Site NAME` | A site name. Used together with `-SiteFilesRoot`: the files come from `<SiteFilesRoot>\<Site>`. |
| `-SiteFilesRoot DIR` | The folder that holds all the site folders. |
| `-Batch FILE.csv` | Make many cards from a CSV list (format in section 3). Prompts between cards. |
| `-NoFlash` | Do not write the image. Only write the ID and site files to a card that is already flashed. |
| `-KeepLineEndings` | Copy site files byte-for-byte (no line-ending conversion). |
| `-AllowNonRemovable` | Also list disks that are not USB/SD. Dangerous. |
| `-ListDisks` | Show the disks the script would offer, then exit. Writes nothing. Use this to find the disk number. |
| `-PauseAtEnd` | Wait for Enter at the end so the window does not close. The `.bat` sets this for you. |

Examples:

```powershell
# Find the disk number of your SD card first (writes nothing)
.\flash-and-provision.ps1 -ListDisks

# One card, no site files
.\flash-and-provision.ps1 -Image D:\images\golden.img -DiskNumber 2 -GatewayId s3-gw-03

# One card, using the folder site-files\siteA
.\flash-and-provision.ps1 -Image D:\images\golden.img -DiskNumber 2 -GatewayId s3-gw-03 -SiteFilesRoot .\site-files -Site siteA

# One card, site files taken straight from one folder
.\flash-and-provision.ps1 -Image D:\images\golden.img -DiskNumber 2 -GatewayId s3-gw-03 -SiteDir .\site-files\siteA

# Many cards from a list
.\flash-and-provision.ps1 -Image D:\images\golden.img -DiskNumber 2 -Batch .\gateways.csv -SiteFilesRoot .\site-files

# Change the ID on a flashed, never-booted card (no re-flash)
.\flash-and-provision.ps1 -NoFlash -DiskNumber 2 -GatewayId s3-gw-07
```

You can also pass these options to the `.bat` from an Administrator Command Prompt:

```
flash-and-provision.bat -Image D:\golden.img -DiskNumber 2 -GatewayId s3-gw-03
```

### Linux

Run with `sudo`.

| Option | What it does |
|---|---|
| `--image PATH` | The golden `.img` file to write. Not needed with `--no-flash`. |
| `--device DEV` | **Required.** The SD card device, for example `/dev/sdb` (or `/dev/mmcblk0`). |
| `--gateway-id ID` | The ID for this card, for example `s3-gw-03`. Required unless you use `--batch`. |
| `--site-dir DIR` | A folder with this gateway's site files, used exactly as given. |
| `--site NAME` | A site name. Used together with `--site-files-root`: the files come from `<root>/<NAME>`. |
| `--site-files-root DIR` | The folder that holds all the site folders. |
| `--batch FILE.csv` | Make many cards from a CSV list. Prompts between cards. |
| `--no-flash` | Do not write the image. Only write the ID and site files to a card that is already flashed. |
| `-h`, `--help` | Show the built-in help. |

Find the device name of your card first with `lsblk` (look for the size and name that match your SD card).

Examples:

```bash
# One card, no site files
sudo ./host/flash-and-provision.sh --image golden.img --device /dev/sdb --gateway-id s3-gw-03

# One card, using site-files/siteA
sudo ./host/flash-and-provision.sh --image golden.img --device /dev/sdb --gateway-id s3-gw-03 \
     --site-files-root site-files/ --site siteA

# Many cards from a list
sudo ./host/flash-and-provision.sh --image golden.img --device /dev/sdb \
     --batch gateways.csv --site-files-root site-files/

# Change the ID on a flashed, never-booted card
sudo ./host/flash-and-provision.sh --device /dev/sdb --gateway-id s3-gw-07 --no-flash
```

> The plain Linux flasher's batch mode uses the same CSV format but does not check the list first or keep the log. For batches, the wizard (option 2) is safer.

---

## 7. Site files

A site folder can hold any of these files. They are copied to the card next to the Gateway ID:

| File | Purpose |
|---|---|
| node-list `.csv` | The list of samples for this site. Usually `samplelist.csv`, but the name is whatever `localDBpath` says inside `pygw_conf.py`. |
| `pygw_conf.py` | The gateway's site configuration. |
| `required-*gw.zip` | The site's required-gateway package (for example `required-3gw.zip`). |

You do not need all three. Anything missing keeps the default that is already built into the image. A site folder with none of them is rejected, because it is almost always a wrong folder name.

---

## 8. Gateway ID rules

The Gateway ID becomes the gateway's **hostname**, so:

- Use **letters, numbers and `-`** only. Example: `s3-gw-03`.
- No spaces, no underscores.
- Do not start or end with `-`.
- Maximum 63 characters.
- **Every gateway needs its own unique ID.**

---

## 9. Safety notes

- **Everything on the SD card is erased** when you flash it. Double-check the size and name shown before you confirm.
- The tools refuse to touch your system disk. `-AllowNonRemovable` removes part of that protection on Windows, so use it only if you fully understand which disk you are choosing.
- Never remove the card, or unplug the reader, while it is writing. If that happens, the card is unusable: flash it again.
- Always **label the finished card** with its Gateway ID.
- If a card is marked **INCOMPLETE**, do not use it.

---

## 10. Troubleshooting

| Problem | What to do |
|---|---|
| **Windows says "Run as Administrator"**, or nothing happens after the prompt | The script needs administrator rights. If you cancelled the Windows prompt, run the `.bat` again and click Yes. |
| **"Cannot find flash-and-provision.ps1"** | The `.bat` and `.ps1` must stay in the same folder. |
| **The wizard does not see my SD card** | Re-plug the reader and wait a few seconds. Press `q` to go back, and try `-ListDisks` (Windows) or `lsblk` (Linux) to see what the computer detects. Cards over 256 GB and the system disk are never shown. |
| **"Card is smaller than the image"** | Use a bigger card. |
| **"CHECKSUM MISMATCH"** | The image is damaged or is not the approved one. Download or copy it again. |
| **"Looks like a compressed file"** | Extract the `.xz` / `.zip` / `.gz` first so you have a plain `.img` file. |
| **"Does not look like a Raspberry Pi disk image"** | Wrong file. Choose the golden `.img`. |
| **"Gateway ID ... not valid"** | See section 8. |
| **"ID was already flashed"** | Each gateway needs a unique ID. Only answer yes if you are deliberately re-making that same card. |
| **Site folder rejected** | It has none of the node-list `.csv` named in `pygw_conf.py`, `pygw_conf.py`, `required-*gw.zip`, or the name is misspelled. |
| **"cannot be used" / flasher refuses the card** | The site's `pygw_conf.py` has a bad `localDBpath` (not a plain quoted `'name.csv'`, or the name has folders, spaces or capital `.CSV`), or it names a node list that is not in the site folder. Nothing was written to the card. Get corrected site files from the project team. |
| **Windows: "You need to format the disk"** after flashing | Click **Cancel**. That is normal for a Raspberry Pi card. |
| **Card marked INCOMPLETE** | It failed or was cancelled. Flash it again. Do not use it as it is. |
| **The window closes too fast (Windows)** | Start it with the `.bat`, which keeps the window open until you press Enter. |