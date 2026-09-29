# S3 Zigbee Gateway - SD Card Flashing Guide

**For:** Production Team
**Applies to:** Raspberry Pi 3B / 3B+ gateways built from the S3 Gateway golden image
**Tool:** `host/flash-and-provision.sh` (Mass Provisioning Kit)

---

## 1. What you are doing (in plain words)

The project team gives you **one golden image**. It is a finished copy of the
gateway software: operating system, database engine, gateway program,
services, security settings. Every gateway uses the same image.

Your job for each gateway is:

1. **Copy the image onto an SD card** ("flashing").
2. **Give that card its own name** - the *Gateway ID*, for example `s3-gw-03`.
   The flasher writes this name into a small file on the card.
3. **Boot the gateway.** On its first boot it reads that file, sets itself up
   (name, database, site files) and starts the gateway service by itself.
4. **Check it** with the validation script, reboot once, and check again.

You do **not** need to install anything on the Pi by hand.

| Stage | Roughly how long |
|---|---|
| Flash + name one card | a few minutes (slow cards take longer) |
| First boot of the gateway | usually under 2 minutes |
| Checks and reboot test | about 10 minutes |

---

## 2. Golden rules

1. **Never guess the device name** when the flasher asks for it (Step 4).
   Writing to the wrong device **erases it permanently** - including your
   own computer's disk.
2. **Every gateway gets its own unique Gateway ID.** Never reuse an ID.
3. **Do not edit files on the SD card by hand.** Only the flasher writes to it.
4. **Do not power off a gateway during its first boot.**
5. **Do not change gateway settings or configuration on the unit by hand.**
   Everything the gateway needs is already in the image. If something looks
   wrong, ask the project team.
6. **If something fails, read the message before trying again.** Do not
   re-flash or reboot in a loop hoping it fixes itself.

---

## 3. Before you start - checklist

**Computer (the "provisioning workstation")**

- [ ] A Linux computer with `sudo` access. The flasher is a Linux script and
      will not run on Windows.
- [ ] The kit folder, containing `host/flash-and-provision.sh`.
- [ ] The golden image file (ends in `.img`) from the project team.
      Write down its **file name and version/date** - you will record it later.
- [ ] A USB SD-card reader.

**For each gateway**

- [ ] An SD card **larger than the image file** (check the image size with
      `ls -lh /path/to/golden.img`).
- [ ] A **Gateway ID** from your batch sheet (see Step 2).
- [ ] **Site files**, *only if* the project team told you this batch is for a
      specific site: `samplelist.csv`, `pygw_conf.py` and
      `required-<site>gw.zip`.

**For the first-boot test**

- [ ] Raspberry Pi 3B/3B+ with its power supply and an Ethernet cable
      to a network that can reach the MQTT broker.
- [ ] The Zigbee USB gateway (dongle).
- [ ] A monitor and USB keyboard (or SSH access, if the project team set it up).
- [ ] The **login password** for the `pi` user (from the project team).

---

## 4. Step-by-step

### Step 1 - Open a terminal in the kit folder

```bash
cd /path/to/s3-gateway-mass-provision-kit
ls host/flash-and-provision.sh
ls -lh /path/to/golden.img
```

You should see both files listed. If the script says "Permission denied" when
you run it later, run this once:

```bash
chmod +x host/flash-and-provision.sh
```

If the project team gave you a checksum for the image, check it now:

```bash
sha256sum /path/to/golden.img
```

The result must match exactly. If it does not, **stop** and ask for the
image again.

### Step 2 - Decide the Gateway IDs

The Gateway ID becomes the gateway's **name on the network** and its **ID in
the MQTT data**, so it must be correct and unique.

Rules for a Gateway ID:

- Letters, numbers and hyphens (`-`) only.
- No spaces, no underscores, no dots.
- Cannot start or end with a hyphen.
- Maximum 63 characters.
- Example: `s3-gw-03`

Write each ID on your batch sheet **before** you start, with the site name
(if any). Use the ID list the project team gave you - do not invent your own.

### Step 3 - Get the site files ready (only if the batch is for a site)

If the project team said this batch is for a specific site, put that site's
files in a folder like this:

```
host/site-files/
    siteA/
        samplelist.csv
        pygw_conf.py
        required-siteAgw.zip
```

- Use **exactly** the files the project team approved.
- **Do not edit them yourself.** Opening and re-saving a CSV in a
  spreadsheet program can add hidden characters that break the node list.
  If a file needs changing, ask the project team.
- **Check the folder exists and has the files before you flash:**

  ```bash
  ls host/site-files/siteA/
  ```

> **Important:** if you type the site folder name wrong, the flasher does
> **not** stop. It quietly writes the card **without** site files. That is why
> you check the folder first, and check the first-boot log later (Step 9).

If the batch has **no** site files, skip this step. The gateway will use the
default node list built into the image.

### Step 4 - Insert the SD card and find its device name

This is the most important step. Take your time.

**4a.** With the SD card reader **not yet plugged in**, run:

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,RM
```

Look at the list once so you know what is already there.

**4b.** Plug in the reader with the SD card, wait 3-5 seconds, run the same
command again:

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,RM
```

**4c.** Find the **new** line. Example:

```
NAME     SIZE MODEL          TRAN RM
sda    476.9G Samsung SSD     sata  0     <- your computer's own disk. NEVER use.
sdb     29.7G Card Reader     usb   1     <- the SD card
```

The right device is the one that:

- **was not there before** you inserted the card,
- has a **size matching your SD card** (a "32 GB" card shows about 29-30G),
- usually shows `usb` under TRAN and `1` under RM (removable).

The device path is `/dev/` + the name, so here it is **`/dev/sdb`**.
(Some built-in card slots appear as `/dev/mmcblk0` instead.)

> **STOP if:**
> - you are not sure which line is the card,
> - the size does not match,
> - the device is the same one your computer boots from.
>
> Ask a colleague or the project team. Do not continue on a guess.

If a file-manager window pops up showing the card, close it. Do not copy
anything onto the card yourself.

### Step 5 - Flash ONE card

Replace the values in the command with yours:

```bash
sudo ./host/flash-and-provision.sh \
    --image /path/to/golden.img \
    --device /dev/sdb \
    --gateway-id s3-gw-03
```

If this gateway needs site files, add the site folder:

```bash
sudo ./host/flash-and-provision.sh \
    --image /path/to/golden.img \
    --device /dev/sdb \
    --gateway-id s3-gw-03 \
    --site-files-root host/site-files/ --site siteA
```

**What happens, and what you will see:**

1. The script shows the device details and asks you to type the device path
   again:

   ```
   About to write to: /dev/sdb
   NAME  SIZE MODEL        MOUNTPOINT
   sdb   29.7G Card Reader

   Type the device path again to confirm (/dev/sdb):
   ```

   Check once more that this is your SD card, then type it exactly
   (`/dev/sdb`) and press Enter. Anything else cancels safely.

2. It copies the image onto the card. You will see a progress line. Wait.
3. It then writes the Gateway ID (and site files, if any) onto the card:

   ```
   ==> Wrote provision.env (GATEWAY_ID=s3-gw-03) to /dev/sdb1
   ==> Done: /dev/sdb -> s3-gw-03
   ```

4. **Wait for the `Done:` line** before you unplug the card. If your reader has
   an activity light, wait until it stops blinking.

5. **Put a label on the card right away** with its Gateway ID. This prevents
   mix-ups.

### Step 6 - Flash MANY cards (batch mode)

For a batch, use a CSV file so you only swap cards when asked.

**6a.** Make your own copy of the example:

```bash
cp host/gateways.csv.example host/gateways.csv
nano host/gateways.csv
```

**6b.** Edit it so it contains **only the header line and one line per card**:

```
gateway_id,site,notes
s3-gw-03,siteA,replacement for damaged unit
s3-gw-04,siteA,new pole run
s3-gw-05,siteB,
```

> **Important - delete every line that starts with `#`** (the explanation
> lines at the bottom of the example file). If you leave them in, the flasher
> treats each one as another card and will ask you to flash cards that do not
> exist. Delete blank lines too.

- Leave `site` empty if the card should not get site files.
- Do not use commas inside a value.

**6c.** Run the batch:

```bash
sudo ./host/flash-and-provision.sh \
    --image /path/to/golden.img \
    --device /dev/sdb \
    --batch host/gateways.csv \
    --site-files-root host/site-files/
```

(Leave out `--site-files-root` if no card in the batch uses site files.)

**6d.** For every card the script shows:

```
############################################################
# Next card: gateway_id=s3-gw-04  site=siteA
# Insert the SD card as /dev/sdb, then press Enter.
############################################################
```

1. Insert the next card in the reader.
2. Run `lsblk` in a second terminal and confirm the card is `/dev/sdb`.
   (The device name is usually the same every time, but **check every time**.)
3. Press Enter, then type the device path to confirm, as in Step 5.
4. Wait for `Done:`, remove the card, **label it**, and continue.

The script has no "resume". If you stop halfway (Ctrl+C), make a new CSV that
contains only the cards not finished yet.

### Step 7 - Fix a wrong or missing ID without re-flashing (special case)

Use this **only** if a card has **never finished its first boot** - for
example the flasher was interrupted, or the log says `no provision.env found`.

```bash
sudo ./host/flash-and-provision.sh \
    --device /dev/sdb \
    --gateway-id s3-gw-07 \
    --no-flash
```

Then boot the gateway again; it will pick up the new ID.

> If a gateway **already booted successfully** with the wrong ID, this does
> **not** change anything - first boot only ever runs once. **Re-flash the
> card** (Step 5) instead.

### Step 8 - First boot of the gateway

1. Put the labelled SD card into the Raspberry Pi.
2. Connect the **Zigbee USB dongle**.
3. Connect the **Ethernet cable**.
4. Connect **power** last.

The first boot sets everything up. It does these things, on its own:

1. Writes the Gateway ID into the gateway settings.
2. Installs the site files (if the card has them).
3. Sets the gateway's network name to the Gateway ID.
4. Creates the database (if needed) and loads the node list.
5. Starts the gateway service.
6. Marks itself as done so it never runs again.

**Do not unplug the power.** Wait about 2 minutes, then continue. If you
are unsure, wait until you can log in and the checks in Step 9 work.

### Step 9 - Log in and run the first checks

Log in on the monitor with user `pi` and the password from the project team.
(SSH works only if the project team set it up for you.)

**9a. Check the name:**

```bash
hostname
```

It must show the **Gateway ID** you wrote on the card (for example
`s3-gw-03`). If it shows something like `pi3-abc123`, go to
*Troubleshooting*.

**9b. Read the first-boot log:**

```bash
journalctl -t s3-gateway-firstboot --no-pager
```

A good run contains lines like these (order may vary a little):

```
Provisioning as GATEWAY_ID=s3-gw-03 (source: /boot/firmware/s3-gateway-provision)
Installing site samplelist.csv into /home/pi/S3Gateway        <- only with site files
Installing site pygw_conf.py into /home/pi/S3Gateway          <- only with site files
Hostname set to s3-gw-03 (static /etc/hostname: s3-gw-03; running: s3-gw-03)
Ensuring PostgreSQL role/database/schema exist
Running s3-gateway-dbup
s3-gateway-dbup: PASS
Provisioning complete for s3-gw-03
```

- The Gateway ID must be the one on the card's label.
- **If this card should have site files, the "Installing site ..." lines must be
  there.** If they are missing, the site folder was wrong: re-flash the card
  with the correct folder.
- Any line that starts with `ERROR` or `WARNING` needs attention.

**9c. Check the service is running:**

```bash
sudo systemctl is-active s3-zigbee-gateway
```

It must print `active`.

> **Always type `sudo`** in front of `systemctl start / stop / restart`.
> Without it you get "Access denied". That is not a fault, you just forgot `sudo`.

**9d. Run the validation script:**

```bash
sudo bash /opt/s3-gateway/app/scripts/validate-handover.sh
```

It prints sections (Service, Database, USB Zigbee, MQTT evidence, and so on),
each line marked `PASS`, `WARN` or `FAIL`, and ends with one of three results:

| Result | Meaning | What to do |
|---|---|---|
| `HANDOVER RESULT: PASS` | Everything is fine. | Continue. |
| `HANDOVER RESULT: PASS WITH WARNINGS` | Works, but something needs a look. | Read the `WARN` lines. |
| `HANDOVER RESULT: FAIL` | At least one `FAIL` line. | **Not acceptable.** See *Troubleshooting*. |

The gateway needs a couple of minutes after it first comes up to connect to
the MQTT broker. If you see MQTT `WARN` lines such as
`no recent MQTT broker-connected evidence found`, **wait 2-3 minutes and run
the script again.** Any `FAIL` is **not** acceptable.

**9e. Confirm MQTT is connected:**

```bash
tail -n 30 /home/pi/S3Gateway/log/mqtt.log
```

You should see lines containing `MQTT transport ready` and
`MQTT broker connected`. If they are missing after 5 minutes, check the
Ethernet cable and network port first, then see *Troubleshooting*.

### Step 10 - Reboot test and final validation

A unit is **not ready for delivery until it recovers by itself after a reboot.**

```bash
sudo reboot
```

Wait for it to start again, log in, then run:

```bash
hostname
sudo systemctl is-active s3-zigbee-gateway
sudo bash /opt/s3-gateway/app/scripts/validate-handover.sh
```

Expected after the reboot:

- `hostname` still shows the Gateway ID.
- The service prints `active`.
- The validation ends with **`HANDOVER RESULT: PASS`**.

If warnings remain, do **not** decide yourself that they are acceptable -
send the output to the project team.

### Step 11 - Record and label

- [ ] Card and gateway labelled with the Gateway ID.
- [ ] Record in your batch sheet (see Section 6).
- [ ] Unit set aside for delivery.

---

## 5. Troubleshooting

Always copy the exact message you see. Do not retype it from memory.

| What you see | Most likely cause | What to do |
|---|---|---|
| `Run with sudo/root` | You forgot `sudo`. | Run the command again with `sudo` in front. |
| `not a block device: /dev/sdX` | The device name is wrong or the card was not detected. | Repeat Step 4. Re-insert the card. |
| `Confirmation did not match. Aborting.` | The retyped path was different. | Nothing was written. Run the command again and type the path exactly. |
| `--image PATH is required` | Image path is wrong or missing. | Check with `ls -lh /path/to/golden.img`. |
| `could not find boot partition` | Card was not read after flashing (bad card, loose reader). | Unplug, re-insert, try again. If it repeats, use another card. |
| Batch asks for cards you do not have | Comment lines left in `gateways.csv`. | Press Ctrl+C, delete lines starting with `#`, restart with only unfinished cards. |
| `hostname` still shows `pi3-xxxxxx` and the log says `no provision.env found` | The card was never given its ID. | Step 7 (`--no-flash`), then reboot the gateway. |
| Log shows `ERROR ... s3-gateway-dbup failed` | The node list or config was rejected (often a bad site file). | Read the lines just above the error. Fix the cause (usually ask the project team for corrected site files), then `sudo reboot` - first boot tries again automatically. |
| "Installing site ..." lines missing but you used site files | Wrong site folder name. | Re-flash the card with the correct `--site` / folder. |
| Validation `FAIL: no CP210x USB device detected` or `no /dev/ttyUSB*` | Zigbee dongle not seen. | Check the dongle and cable, try another USB port. Test with `lsusb \| grep -i cp210` and `ls -l /dev/ttyUSB*`. |
| Validation `FAIL: s3-zigbee-gateway not active` | The service is not running. | See the block below this table. |
| MQTT warnings or no "MQTT broker connected" line after 5+ minutes | No network route to the broker (cable, port, firewall), or the Pi's clock is wrong. | Check the Ethernet cable and network port. Check `date` shows today's date. Look at `tail -n 50 /home/pi/S3Gateway/log/mqtt.log`. If the network is fine and it still fails, send the output to the project team - do not try to change gateway settings yourself. |
| `Failed to start ...: Access denied` | You ran `systemctl` without `sudo`. | Run it again with `sudo`. |
| No lights / no screen output at all | Bad card, bad power supply, or a bad flash. | Try a different power supply, then re-flash, then try another card. |
| Wrong ID on a gateway that already booted OK | The ID is fixed after first boot. | Re-flash the card with the correct ID (Step 5). |

**If the gateway service is not active**, collect this and send it to the
project team:

```bash
sudo systemctl status s3-zigbee-gateway --no-pager
sudo journalctl -u s3-zigbee-gateway -b --no-pager | tail -n 50
sudo journalctl -t s3-gateway-firstboot --no-pager
```

You may try one restart (`sudo systemctl restart s3-zigbee-gateway`). If it
still fails, stop and send the output. Do not keep retrying.

---

## 6. Record for each gateway

Keep one row per gateway. **Do not write passwords here.**

| Gateway ID | Site | Image file / version | Flash date | Flashed by | Zigbee dongle (serial/label) | First-boot log OK | Validation after reboot | Notes |
|---|---|---|---|---|---|---|---|---|
| s3-gw-03 | siteA | | | | | [ ] | PASS / other: | |

Per-gateway acceptance checklist:

- [ ] Card flashed and labelled with a unique Gateway ID.
- [ ] `hostname` equals the Gateway ID.
- [ ] First-boot log shows `Provisioning complete` and no `ERROR`.
- [ ] Site files installed (if the batch is for a site).
- [ ] Zigbee USB dongle detected.
- [ ] MQTT log shows the gateway connected to the broker.
- [ ] Reboot test passed.
- [ ] `validate-handover.sh` returns `PASS` after the reboot.

---

## 7. Quick reference

| I want to... | Command |
|---|---|
| See disks (find the SD card) | `lsblk -o NAME,SIZE,MODEL,TRAN,RM` |
| Flash one card | `sudo ./host/flash-and-provision.sh --image IMG --device /dev/sdX --gateway-id ID` |
| Flash one card with site files | add `--site-files-root host/site-files/ --site SITE` |
| Flash many cards | `... --batch host/gateways.csv [--site-files-root host/site-files/]` |
| Fix ID on a never-booted card | `sudo ./host/flash-and-provision.sh --device /dev/sdX --gateway-id ID --no-flash` |
| Check the gateway name | `hostname` |
| Read the first-boot log | `journalctl -t s3-gateway-firstboot --no-pager` |
| Is the service running? | `sudo systemctl is-active s3-zigbee-gateway` |
| Run the acceptance check | `sudo bash /opt/s3-gateway/app/scripts/validate-handover.sh` |
| Restart the gateway service | `sudo systemctl restart s3-zigbee-gateway` |
| Watch the MQTT log | `tail -n 30 /home/pi/S3Gateway/log/mqtt.log` |
| Look for the Zigbee dongle | `lsusb \| grep -i cp210` and `ls -l /dev/ttyUSB*` |

---

## 8. Background (optional reading)

**What the flasher puts on the card.** After copying the image, it creates a
folder called `s3-gateway-provision` on the card's small boot partition
(the part a computer can normally read). Inside:

- `provision.env` - one line, `GATEWAY_ID=<the ID>`
- `samplelist.csv`, `pygw_conf.py`, `required-<site>gw.zip` - only if you
  gave it a site folder

**Why a first boot?** The database and some settings can only be created on a
running system, not while the image is being built. So the image contains a
one-time first-boot service that finishes the job on the real gateway, then
switches itself off.

**Why it can repeat.** If first boot **fails**, it is *not* marked as done, so
it tries again on the next boot. Once it **succeeds**, it never runs again -
which is why a wrong ID on an already-booted gateway needs a re-flash.