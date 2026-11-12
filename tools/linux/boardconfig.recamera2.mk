# Minimal board descriptor for reCamera Pro (RV1126B, eMMC, single slot).
#
# tools/linux/rkflash.sh reads this file line by line with awk; it is never
# sourced by a shell. Only the literals below are consumed:
#   - RK_APP_TYPE          -> factory-reset target guard
#   - RK_BOOT_MEDIUM       -> factory-reset target guard (emmc only)
#   - RK_PARTITION_CMD_IN_ENV -> cross-checked against the partition table
#                                embedded in the env.img being flashed
#
# Keep this in sync with the SDK board config
# project/cfg/BoardConfig_Recamera2/BoardConfig-EMMC-RK801-RV1126B_V1-IPC_64BIT.mk

export RK_APP_TYPE=RKIPC_RV1126B_RECAMERA2
export RK_BOOT_MEDIUM=emmc
export RK_PARTITION_CMD_IN_ENV="32K(env),512K@32K(idblock),4M@1M(uboot),64K(misc),10M(recovery),11M(boot),3G(rootfs),-(userdata),"