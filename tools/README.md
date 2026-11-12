# Flashing tools

**English** | [简体中文](README_zh.md)

Rockchip flashing tools for the **reCamera Pro** (RV1126B), bundled here so that a
customer can go from "boxed camera" or "bricked camera" to a freshly flashed device
without downloading anything else.

| Tool | Platform | What it is for |
| --- | --- | --- |
| [SocToolKit](#soctoolkit-windows--linux) | Windows, Linux | GUI: flash the full image set over USB, upgrade `update.img`, create SD boot/upgrade cards |
| [Linux_Upgrade_Tool](#linux_upgrade_tool) | Linux | CLI `upgrade_tool` (USB only) with the same capabilities as the GUI |
| [`rkflash.sh`](#rkflashsh-recommended-for-linux) | Linux | One-command wrapper: preflight-checks the partition table, then flashes partition by partition |
| [DriverAssitant](#driverassitant-windows-only) | Windows | USB driver installer (rockusb / ADB) |

> These are vendor tools. Only the flashing-related ones are included; build toolchains,
> ISP tuning tools and mass-production tools stay in the SDK. Copyright belongs to
> Rockchip — see `license.txt` / `revison.log` in each tool directory.

---

## SocToolKit (Windows / Linux)

`tools/windows/SocToolKit/SocToolKit.exe` — v2.54, Windows
`tools/linux/SocToolKit/SocToolKit` — v2.54, Linux (Qt)

The graphical flashing tool. It scans USB for a device in **rockusb** (Loader or Maskrom)
mode and writes the images you select to their partitions.

**Tabs**

- **Download** — write partition images (`download.bin`, `env`, `idblock`, `uboot`, `boot`,
  `rootfs`, …) over USB or a serial (COM) link. This is what you use to flash reCamera Pro.
- **Firmware** — download a single `update.img` package (the "Upgrade" button).
- **SDTool** — create an SD card that boots or upgrades another device.

**Basic flow**

1. Make sure the device is in boot mode (hold **BOOT**, press **RESET**).
2. Confirm the chip: **Tool → Chip Selection → RV1126B**.
3. Choose **USB**, click **Search Path…** and select the folder that contains the images
   (the folder is scanned and the image list is filled automatically).
4. Select the images (including `DownloadBin`) and click **Download**.

**Notes**

- `config.json` ships with a default chip: the Linux copy defaults to `RV1126B`, the
  Windows copy defaults to `RV1103B` — **always verify the Chip Selection dialog**.
- On Linux, install the udev rules first (see below) and run the tool as root.
- The bundled `bin/linux|windows/` directory already contains `upgrade_tool`, `afptool`,
  `rkImageMaker` and `programmer_image_tool`; you do not need to install them separately.

---

## Linux_Upgrade_Tool

`tools/linux/Linux_Upgrade_Tool/`

Command-line flashing over USB. Contents:

| File | Purpose |
| --- | --- |
| `upgrade_tool` | The CLI itself (v2.26) |
| `88-rockusb.rules` | udev rule that gives non-root access to Rockchip USB devices |
| `命令行开发工具使用文档.pdf` | Rockchip's command reference (Chinese) |
| `revision.txt` | Version history |
| `config.ini` | Optional tuning switches (all commented out by default) |

**Install the udev rule once**

```bash
sudo cp 88-rockusb.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**Common commands**

```bash
./upgrade_tool LD                  # list connected devices (mode=Loader/Maskrom)
./upgrade_tool RD                  # reset the device
./upgrade_tool DB download.bin     # download a loader (Maskrom -> Loader)
./upgrade_tool WL <offset> <count> file.img   # write <count> sectors at <offset> (512B sectors)
./upgrade_tool UL uboot.img        # upload/upgrade a loader image
./upgrade_tool UF update.img       # upgrade a full update.img
./upgrade_tool EF download.bin     # erase the device
```

Offsets/counts come from the partition table. Prefer `rkflash.sh` below, which derives them
from `env.img` automatically and validates them first.

---

## `rkflash.sh` (recommended for Linux)

`tools/linux/rkflash.sh`

A safety-checked wrapper around `upgrade_tool`. Before writing anything it:

1. finds exactly one connected device and requires Loader or Maskrom mode,
2. reads the partition table (`blkdevparts=…`) from `env.img`,
3. cross-checks it against `tools/linux/boardconfig.recamera2.mk`,
4. verifies that each image exists, is a regular file, and fits in its partition.

It refuses to write a grow-to-end partition (`userdata`) and never touches `misc` or
`userdata` for the normal actions.

```
Usage:
  rkflash.sh [all|system]       Flash env/idblock/uboot/recovery/boot/rootfs;
                                  preserve misc and userdata (default).
  rkflash.sh factory-reset      Flash a dedicated normal-boot factory-reset flag;
                                  userdata.img is never used.
  rkflash.sh <partition> [img]  Flash one partition from env.img offsets.
  rkflash.sh update [img]       Flash update.img through UpgradeFirmware.
  rkflash.sh loader [img]       Upgrade only the loader.
  rkflash.sh rd                 Reset the connected device.
  rkflash.sh erase I-UNDERSTAND-THIS-ERASES-THE-DEVICE
```

**Environment variables**

| Variable | Default | Meaning |
| --- | --- | --- |
| `RKFLASH_IMAGE_DIR` | `<repo-root>/firmware` | Where the `.img` files are |
| `RKFLASH_UPGRADE_TOOL` | `tools/linux/Linux_Upgrade_Tool/upgrade_tool` | CLI to drive |
| `RKFLASH_BOARD_CONFIG` | `tools/linux/boardconfig.recamera2.mk` | Expected layout |
| `RKFLASH_DRY_RUN=1` | off | Validate and print commands, no device access |
| `RKFLASH_LOADER_WAIT_ATTEMPTS` / `_INTERVAL` | `10` / `1` | How long to wait for Maskrom → Loader |

**Examples**

```bash
cd tools/linux
RKFLASH_DRY_RUN=1 ./rkflash.sh all                    # first, always: see what would happen
./rkflash.sh all                                      # flash, keep misc + userdata
RKFLASH_IMAGE_DIR=/mnt/fw/1.3.1 ./rkflash.sh all
./rkflash.sh boot /mnt/fw/boot.img                    # single partition
./rkflash.sh rd
```

**Warnings**

- `factory-reset` flashes a flag into `misc`; the next normal boot formats `userdata`.
- `erase` wipes the whole device and requires the literal confirmation phrase.
- Back up settings and recordings before flashing — `all` keeps `userdata`, but `erase`
  and `factory-reset` do not.
- There is no A/B slot: keep the device powered and the USB cable connected during the
  download. An interrupted write leaves a device that must be reflashed from the start.

---

## DriverAssitant (Windows only)

`tools/windows/DriverAssitant_v5.12.zip`

Rockchip USB driver package (v5.12). Unzip it and run the installer **before** connecting
the camera in boot mode; without it Windows does not create the rockusb device and
SocToolKit cannot see the camera. Rebooting after installation is recommended.

The package also installs the ADB driver used by the device's terminal/debug features.

---

## Which one should I use?

| Situation | Use |
| --- | --- |
| Windows PC, first time | DriverAssitant → SocToolKit |
| Linux desktop | SocToolKit (GUI) or `rkflash.sh` (CLI) |
| Linux CI / headless / scripted | `rkflash.sh` with `RKFLASH_DRY_RUN=1` first |
| Only need to upgrade firmware on a booting device | Web UI OTA — see the [main README](../README.md) |