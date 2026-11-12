# 刷写工具

[English](README.md) | **简体中文**

面向 **reCamera Pro**（RV1126B）的瑞芯微刷写工具集合。仓库内置这些工具，是为了让用户
从"刚开箱"或"设备变砖"到"重新刷好固件"都不用再去找别的下载。

| 工具 | 平台 | 作用 |
| --- | --- | --- |
| [SocToolKit](#soctoolkitwindows--linux) | Windows、Linux | 图形界面：通过 USB 刷整套镜像、升级 `update.img`、制作 SD 启动/升级卡 |
| [Linux_Upgrade_Tool](#linux_upgrade_tool) | Linux | 命令行 `upgrade_tool`（仅 USB），能力与图形界面一致 |
| [`rkflash.sh`](#rkflashshlinux-推荐) | Linux | 一条命令封装：先做分区表预检，再逐分区刷写 |
| [DriverAssitant](#driverassitant仅-windows) | Windows | USB 驱动安装包（rockusb / ADB） |

> 这些都是厂商工具。本仓库只收录了与刷机相关的部分；交叉编译工具链、ISP 调试与量产工具
> 仍保留在 SDK 中。版权归瑞芯微（Rockchip）所有，各工具目录下的 `license.txt` /
> `revison.log` 为原始版权与版本说明。

---

## SocToolKit（Windows / Linux）

`tools/windows/SocToolKit/SocToolKit.exe` —— v2.54，Windows
`tools/linux/SocToolKit/SocToolKit` —— v2.54，Linux（Qt）

图形化刷写工具。它会扫描处于 **rockusb**（Loader 或 Maskrom）模式的 USB 设备，把选中的
镜像写到对应分区。

**页签**

- **Download** —— 通过 USB 或串口（COM）写分区镜像（`download.bin`、`env`、`idblock`、
  `uboot`、`boot`、`rootfs` 等）。刷 reCamera Pro 用的就是这个页签。
- **Firmware** —— 通过 "Upgrade" 按钮下载单个 `update.img` 整包。
- **SDTool** —— 制作可启动或可升级其它设备的 SD 卡。

**基本流程**

1. 让设备进入 boot 模式（按住 **BOOT**，按一下 **RESET**）。
2. 确认芯片：**Tool → Chip Selection → RV1126B**。
3. 选择 **USB**，点击 **Search Path…** 选择镜像所在文件夹（工具会扫描目录并自动列出镜像）。
4. 勾选镜像（包括 `DownloadBin`），点击 **Download**。

**注意**

- `config.json` 自带默认芯片：Linux 版默认 `RV1126B`，Windows 版默认 `RV1103B`，
  **务必在 Chip Selection 对话框里确认**。
- Linux 下请先安装 udev 规则（见下文），并以 root 运行。
- 自带的 `bin/linux|windows/` 目录里已有 `upgrade_tool`、`afptool`、`rkImageMaker`、
  `programmer_image_tool`，无需另外安装。

---

## Linux_Upgrade_Tool

`tools/linux/Linux_Upgrade_Tool/`

USB 命令行刷写工具。目录内容：

| 文件 | 作用 |
| --- | --- |
| `upgrade_tool` | 命令行主程序（v2.26） |
| `88-rockusb.rules` | udev 规则，让普通用户也能访问瑞芯微 USB 设备 |
| `命令行开发工具使用文档.pdf` | 瑞芯微命令手册 |
| `revision.txt` | 版本历史 |
| `config.ini` | 可选调优开关（默认全部注释） |

**先安装一次 udev 规则**

```bash
sudo cp 88-rockusb.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**常用命令**

```bash
./upgrade_tool LD                  # 列出已连接设备（mode=Loader/Maskrom）
./upgrade_tool RD                  # 复位设备
./upgrade_tool DB download.bin     # 下载 loader（Maskrom -> Loader）
./upgrade_tool WL <offset> <count> file.img   # 在 <offset> 处写 <count> 个扇区（512B/扇区）
./upgrade_tool UL uboot.img        # 升级 loader 镜像
./upgrade_tool UF update.img       # 升级整包 update.img
./upgrade_tool EF download.bin     # 擦除设备
```

偏移与扇区数来自分区表。建议直接用下面的 `rkflash.sh`，它会自动从 `env.img` 推导并先做校验。

---

## `rkflash.sh`（Linux 推荐）

`tools/linux/rkflash.sh`

对 `upgrade_tool` 做的安全封装。写盘之前它会：

1. 确认只连接了一台设备，且处于 Loader 或 Maskrom 模式；
2. 从 `env.img` 中读取分区表（`blkdevparts=…`）；
3. 与 `tools/linux/boardconfig.recamera2.mk` 交叉校验；
4. 检查每个镜像存在、是普通文件、且不超过对应分区大小。

它拒绝向 grow-to-end 分区（`userdata`）写镜像，常规操作也绝不触碰 `misc` 与 `userdata`。

```
Usage:
  rkflash.sh [all|system]       刷 env/idblock/uboot/recovery/boot/rootfs；
                                  保留 misc 与 userdata（默认）。
  rkflash.sh factory-reset      写入"恢复出厂"标志；从不使用 userdata.img。
  rkflash.sh <partition> [img]  按 env.img 偏移刷单个分区。
  rkflash.sh update [img]       通过 UpgradeFirmware 刷 update.img。
  rkflash.sh loader [img]       只升级 loader。
  rkflash.sh rd                 复位已连接设备。
  rkflash.sh erase I-UNDERSTAND-THIS-ERASES-THE-DEVICE
```

**环境变量**

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `RKFLASH_IMAGE_DIR` | `<仓库根>/firmware` | `.img` 所在目录 |
| `RKFLASH_UPGRADE_TOOL` | `tools/linux/Linux_Upgrade_Tool/upgrade_tool` | 实际调用的命令行工具 |
| `RKFLASH_BOARD_CONFIG` | `tools/linux/boardconfig.recamera2.mk` | 期望的分区布局 |
| `RKFLASH_DRY_RUN=1` | 关闭 | 只校验并打印命令，不访问设备 |
| `RKFLASH_LOADER_WAIT_ATTEMPTS` / `_INTERVAL` | `10` / `1` | Maskrom → Loader 的等待次数/间隔 |

**示例**

```bash
cd tools/linux
RKFLASH_DRY_RUN=1 ./rkflash.sh all                    # 先干跑：看清楚要做什么
./rkflash.sh all                                      # 刷写，保留 misc + userdata
RKFLASH_IMAGE_DIR=/mnt/fw/1.3.1 ./rkflash.sh all
./rkflash.sh boot /mnt/fw/boot.img                    # 只刷一个分区
./rkflash.sh rd
```

**警告**

- `factory-reset` 会往 `misc` 写标志，下次正常启动会格式化 `userdata`。
- `erase` 会擦除整台设备，必须输入规定的确认短语。
- 刷写前先备份配置与录像：`all` 会保留 `userdata`，但 `erase` 和 `factory-reset` 不会。
- 没有 A/B 分区：刷写过程中保持供电、不要断开 USB。写盘被打断只能从头重新刷写。

---

## DriverAssitant（仅 Windows）

`tools/windows/DriverAssitant_v5.12.zip`

瑞芯微 USB 驱动包（v5.12）。解压后先运行安装程序，**再**把摄像机接入 boot 模式；否则
Windows 不会创建 rockusb 设备，SocToolKit 也就看不到摄像机。安装后建议重启。

该驱动包同时安装设备终端/调试功能所用的 ADB 驱动。

---

## 该用哪一个？

| 场景 | 选择 |
| --- | --- |
| Windows，第一次刷机 | DriverAssitant → SocToolKit |
| Linux 桌面 | SocToolKit（图形界面）或 `rkflash.sh`（命令行） |
| Linux CI / 无界面 / 脚本化 | `rkflash.sh`，先用 `RKFLASH_DRY_RUN=1` 干跑 |
| 设备能正常启动、只想升级固件 | Web 界面 OTA —— 见[主 README](../README_zh.md) |