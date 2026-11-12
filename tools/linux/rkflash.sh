#!/bin/bash

# Fail before reset on the first missing or rejected write. The former helper
# silently continued after missing parameter.txt/trust.img/userdata.img, and
# its partition-name writes were not preflighted against the env.img produced
# by the current build.
set -euo pipefail

COMMON_DIR=$(cd "$(dirname "$(realpath "$0")")" && pwd)
REPO_DIR=$(realpath "$COMMON_DIR/../..")
UPGRADETOOL=${RKFLASH_UPGRADE_TOOL:-$COMMON_DIR/Linux_Upgrade_Tool/upgrade_tool}
ROCKDEV_DIR=${RKFLASH_IMAGE_DIR:-$REPO_DIR/firmware}
BOARD_CONFIG=${RKFLASH_BOARD_CONFIG:-$COMMON_DIR/boardconfig.recamera2.mk}
LOADER="$ROCKDEV_DIR/download.bin"
ENV_IMAGE="$ROCKDEV_DIR/env.img"
UPDATE_IMAGE="$ROCKDEV_DIR/update.img"
DRY_RUN=${RKFLASH_DRY_RUN:-0}
LOADER_WAIT_ATTEMPTS=${RKFLASH_LOADER_WAIT_ATTEMPTS:-10}
LOADER_WAIT_INTERVAL=${RKFLASH_LOADER_WAIT_INTERVAL:-1}
FACTORY_RESET_FLAG=cmd_wipe_userdata
FACTORY_RESET_FLAG_OFFSET=6144
FACTORY_RESET_FLAG_BYTES=64
FACTORY_RESET_MISC_SECTORS=128
FACTORY_RESET_APP_TYPE=RKIPC_RV1126B_RECAMERA2
FACTORY_RESET_MISC_IMAGE=

DEVICE_LIST_OUTPUT=
DEVICE_DECLARED_COUNT=
DEVICE_LINE_COUNT=
DEVICE_MODE=

declare -a PARTITION_ORDER=()
declare -A PARTITION_OFFSET=()
declare -A PARTITION_SIZE=()

cleanup_factory_reset_misc()
{
	if [ -n "$FACTORY_RESET_MISC_IMAGE" ] &&
	   [ -f "$FACTORY_RESET_MISC_IMAGE" ] &&
	   [ ! -L "$FACTORY_RESET_MISC_IMAGE" ]; then
		rm -f -- "$FACTORY_RESET_MISC_IMAGE"
	fi
}

trap cleanup_factory_reset_misc EXIT

die()
{
	printf 'rkflash: ERROR: %s\n' "$*" >&2
	exit 1
}

usage()
{
	cat <<'EOF'
Usage:
  rkflash.sh [all|system]       Flash env/idblock/uboot/recovery/boot/rootfs;
                                  preserve misc and userdata (default).
  rkflash.sh factory-reset     Flash a dedicated normal-boot factory-reset
                                  flag; userdata.img is never used.
  rkflash.sh <partition> [img] Flash one partition from env.img offsets.
  rkflash.sh update [img]      Flash update.img through UpgradeFirmware.
  rkflash.sh loader [img]      Upgrade only the loader.
  rkflash.sh rd                Reset the connected device.
  rkflash.sh erase I-UNDERSTAND-THIS-ERASES-THE-DEVICE

Images are read from <repo-root>/firmware by default (unpack the release image
package there); override with RKFLASH_IMAGE_DIR. The upgrade_tool comes from
tools/linux/Linux_Upgrade_Tool; override with RKFLASH_UPGRADE_TOOL.

The active reCamera2 layout uses a grow-to-end userdata partition and does not
generate userdata.img. Any userdata.img found in the image directory is
deliberately ignored. The factory-reset action is restricted to the audited
reCamera2 eMMC single-slot layout; the expected layout is read from
tools/linux/boardconfig.recamera2.mk (override with RKFLASH_BOARD_CONFIG).
Set RKFLASH_DRY_RUN=1 to print validated commands without a device.
EOF
}

run_upgrade_tool()
{
	printf 'rkflash:'
	printf ' %q' "$UPGRADETOOL" "$@"
	printf '\n'
	if [ "$DRY_RUN" = 1 ]; then
		return 0
	fi
	"$UPGRADETOOL" "$@"
}

read_device_snapshot()
{
	local header_count

	printf 'rkflash: %q LD\n' "$UPGRADETOOL" >&2
	if ! DEVICE_LIST_OUTPUT=$("$UPGRADETOOL" LD 2>&1); then
		printf '%s\n' "$DEVICE_LIST_OUTPUT" >&2
		die "failed to query connected Rockchip devices"
	fi
	header_count=$(printf '%s\n' "$DEVICE_LIST_OUTPUT" | awk '
		/^List of rockusb connected\([0-9]+\)[[:space:]]*$/ { count++ }
		END { print count + 0 }
	')
	[ "$header_count" -eq 1 ] || {
		printf '%s\n' "$DEVICE_LIST_OUTPUT" >&2
		die "could not parse upgrade_tool LD output"
	}
	DEVICE_DECLARED_COUNT=$(printf '%s\n' "$DEVICE_LIST_OUTPUT" | sed -n \
		's/^List of rockusb connected(\([0-9][0-9]*\))[[:space:]]*$/\1/p')
	DEVICE_LINE_COUNT=$(printf '%s\n' "$DEVICE_LIST_OUTPUT" | awk '
		/^DevNo=/ { count++ }
		END { print count + 0 }
	')
	[ "$DEVICE_DECLARED_COUNT" -eq "$DEVICE_LINE_COUNT" ] || {
		printf '%s\n' "$DEVICE_LIST_OUTPUT" >&2
		die "upgrade_tool LD device count is inconsistent"
	}
	DEVICE_MODE=
	if [ "$DEVICE_LINE_COUNT" -eq 1 ]; then
		DEVICE_MODE=$(printf '%s\n' "$DEVICE_LIST_OUTPUT" | awk '
			/^DevNo=/ {
				for (field = 1; field <= NF; field++) {
					if ($field ~ /^Mode=/) {
						sub(/^Mode=/, "", $field)
						print $field
					}
				}
			}
		')
		[ -n "$DEVICE_MODE" ] || {
			printf '%s\n' "$DEVICE_LIST_OUTPUT" >&2
			die "upgrade_tool LD omitted the device mode"
		}
	fi
}

require_single_device_mode()
{
	read_device_snapshot
	[ "$DEVICE_DECLARED_COUNT" -eq 1 ] ||
		die "expected exactly one Rockchip device; found $DEVICE_DECLARED_COUNT"
	case "$DEVICE_MODE" in
		Maskrom|Loader)
			;;
		Msc)
			die "the connected device is in unsupported Msc mode"
			;;
		*)
			die "the connected device reported unsupported mode '$DEVICE_MODE'"
			;;
	esac
}

wait_for_loader_mode()
{
	local attempt

	[[ "$LOADER_WAIT_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] ||
		die "RKFLASH_LOADER_WAIT_ATTEMPTS must be a positive integer"
	[[ "$LOADER_WAIT_INTERVAL" =~ ^[0-9]+$ ]] ||
		die "RKFLASH_LOADER_WAIT_INTERVAL must be a non-negative integer"
	for ((attempt = 1; attempt <= LOADER_WAIT_ATTEMPTS; attempt++)); do
		read_device_snapshot
		case "$DEVICE_DECLARED_COUNT:$DEVICE_MODE" in
			1:Loader)
				printf 'rkflash: device entered Loader mode\n'
				return 0
				;;
			0:)
				;;
			1:Maskrom)
				;;
			1:Msc)
				die "device changed to unsupported Msc mode after DownloadBoot"
				;;
			1:*)
				die "device reported unsupported mode '$DEVICE_MODE' after DownloadBoot"
				;;
			*)
				die "expected exactly one Rockchip device after DownloadBoot; found $DEVICE_DECLARED_COUNT"
				;;
		esac
		if [ "$attempt" -lt "$LOADER_WAIT_ATTEMPTS" ] &&
		   [ "$LOADER_WAIT_INTERVAL" -gt 0 ]; then
			sleep "$LOADER_WAIT_INTERVAL"
		fi
	done
	die "device did not enter Loader mode after DownloadBoot"
}

quantity_to_bytes()
{
	local raw="$1"
	local suffix="${raw: -1}"
	local number multiplier=1

	case "$suffix" in
		K|k) number=${raw::-1}; multiplier=1024 ;;
		M|m) number=${raw::-1}; multiplier=$((1024 * 1024)) ;;
		G|g) number=${raw::-1}; multiplier=$((1024 * 1024 * 1024)) ;;
		T|t) number=${raw::-1}; multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
		*) number=$raw ;;
	esac
	if [[ "$number" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$((10#$number * multiplier))"
	elif [[ "$number" =~ ^0[xX][0-9a-fA-F]+$ ]]; then
		printf '%s\n' "$((number * multiplier))"
	else
		die "invalid partition quantity: $raw"
	fi
}

partition_spec_from_env()
{
	local env_line
	[ -f "$ENV_IMAGE" ] && [ ! -L "$ENV_IMAGE" ] ||
		die "missing regular env image: $ENV_IMAGE"
	env_line=$(strings "$ENV_IMAGE" | awk '
		/^(blkdevparts=mmcblk0:|mtdparts=(sfc_nor|spi-nand0|rk-nand):)/ {
			print
			exit
		}')
	[ -n "$env_line" ] || die "env.img contains no supported partition table"
	printf '%s\n' "${env_line#*:}"
}

verify_active_board_layout()
{
	local image_spec="$1"
	local configured_spec

	# Reject an env.img left by a different lunch target. Do not source the board
	# file: extracting this literal is intentionally side-effect free.
	if [ -e "$BOARD_CONFIG" ]; then
		configured_spec=$(awk -F '"' \
			'/^[[:space:]]*export[[:space:]]+RK_PARTITION_CMD_IN_ENV="/ {
				value = $2
			}
			END { print value }
		' "$BOARD_CONFIG")
		if [ -n "$configured_spec" ] && [ "$configured_spec" != "$image_spec" ]; then
			die "env.img partition table does not match $BOARD_CONFIG"
		fi
	fi
}

read_board_config_token()
{
	local variable_name="$1"

	[ -f "$BOARD_CONFIG" ] || return 1
	awk -v variable_name="$variable_name" '
		{
			assignment = "^[[:space:]]*export[[:space:]]+" variable_name \
				"[[:space:]]*="
			if ($0 !~ assignment) {
				next
			}
			declarations++
			value = $0
			sub(assignment "[[:space:]]*", "", value)
			sub(/[[:space:]]*$/, "", value)
			if (value !~ /^[A-Za-z0-9_]+$/) {
				invalid = 1
			}
		}
		END {
			if (declarations != 1 || invalid || value == "") {
				exit 1
			}
			print value
		}
	' "$BOARD_CONFIG"
}

verify_factory_reset_target()
{
	local app_type boot_medium name required_name last_index
	local supported_table_count emmc_table_count

	if ! app_type=$(read_board_config_token RK_APP_TYPE); then
		die "factory-reset requires exactly one literal RK_APP_TYPE in $BOARD_CONFIG"
	fi
	[ "$app_type" = "$FACTORY_RESET_APP_TYPE" ] ||
		die "factory-reset is restricted to RK_APP_TYPE=$FACTORY_RESET_APP_TYPE; found '$app_type'"
	if ! boot_medium=$(read_board_config_token RK_BOOT_MEDIUM); then
		die "factory-reset requires exactly one literal RK_BOOT_MEDIUM in $BOARD_CONFIG"
	fi
	[ "$boot_medium" = emmc ] ||
		die "factory-reset is restricted to the audited eMMC layout; found '$boot_medium'"

	read -r supported_table_count emmc_table_count < <(strings "$ENV_IMAGE" | awk '
		/^(blkdevparts=mmcblk0:|mtdparts=(sfc_nor|spi-nand0|rk-nand):)/ {
			supported++
		}
		/^blkdevparts=mmcblk0:/ {
			emmc++
		}
		END { print supported + 0, emmc + 0 }
	')
	[ "$supported_table_count" -eq 1 ] && [ "$emmc_table_count" -eq 1 ] ||
		die "factory-reset requires one unambiguous mmcblk0 partition table in env.img"

	for name in "${PARTITION_ORDER[@]}"; do
		case "$name" in
			*_a|*_b)
				die "factory-reset requires a single-slot partition layout; found '$name'"
				;;
		esac
	done
	for required_name in uboot misc recovery boot rootfs userdata; do
		[ -n "${PARTITION_OFFSET[$required_name]+x}" ] ||
			die "factory-reset requires the single-slot '$required_name' partition"
	done
	[ "${PARTITION_SIZE[misc]}" = "$FACTORY_RESET_MISC_SECTORS" ] ||
		die "factory-reset requires the audited 64K misc partition"
	[ "${PARTITION_SIZE[userdata]}" = - ] ||
		die "factory-reset requires grow-to-end userdata"
	last_index=$((${#PARTITION_ORDER[@]} - 1))
	[ "${PARTITION_ORDER[$last_index]}" = userdata ] ||
		die "factory-reset requires userdata to be the final partition"
}

parse_partition_spec()
{
	local spec="$1"
	local entry size_text offset_text name bytes sectors
	local next_offset=0
	local old_ifs=$IFS

	IFS=,
	read -r -a entries <<< "$spec"
	IFS=$old_ifs
	for entry in "${entries[@]}"; do
		[ -n "$entry" ] || continue
		if [[ ! "$entry" =~ ^([^@()]+)(@([^()]+))?\(([^()]+)\)$ ]]; then
			die "invalid partition entry in env.img: $entry"
		fi
		size_text=${BASH_REMATCH[1]}
		offset_text=${BASH_REMATCH[3]}
		name=${BASH_REMATCH[4]}
		name=${name%%:*}
		[ -z "${PARTITION_OFFSET[$name]+x}" ] ||
			die "duplicate partition in env.img: $name"
		if [ -n "$offset_text" ]; then
			bytes=$(quantity_to_bytes "$offset_text")
			[ $((bytes % 512)) -eq 0 ] ||
				die "partition offset is not sector aligned: $entry"
			next_offset=$((bytes / 512))
		fi
		PARTITION_ORDER+=("$name")
		PARTITION_OFFSET[$name]=$next_offset
		if [ "$size_text" = - ]; then
			PARTITION_SIZE[$name]=-
			continue
		fi
		bytes=$(quantity_to_bytes "$size_text")
		[ $((bytes % 512)) -eq 0 ] ||
			die "partition size is not sector aligned: $entry"
		sectors=$((bytes / 512))
		[ "$sectors" -gt 0 ] || die "empty partition in env.img: $name"
		PARTITION_SIZE[$name]=$sectors
		next_offset=$((next_offset + sectors))
	done
	[ "${#PARTITION_ORDER[@]}" -gt 0 ] || die "empty partition table"
}

validate_partition_image()
{
	local name="$1"
	local image="$2"
	local image_bytes maximum_bytes

	[ -n "${PARTITION_OFFSET[$name]+x}" ] ||
		die "partition '$name' is absent from env.img"
	[ -f "$image" ] && [ ! -L "$image" ] ||
		die "missing regular image for $name: $image"
	[ "${PARTITION_SIZE[$name]}" != - ] ||
		die "refusing an image write to grow-to-end partition '$name'"
	image_bytes=$(stat -c '%s' "$image")
	maximum_bytes=$((PARTITION_SIZE[$name] * 512))
	[ "$image_bytes" -le "$maximum_bytes" ] ||
		die "$image exceeds the $name partition size"
}

prepare_factory_reset_misc()
{
	local misc_bytes flag_text

	[ -n "${PARTITION_OFFSET[misc]+x}" ] ||
		die "partition 'misc' is absent from env.img"
	[ "${PARTITION_SIZE[misc]}" != - ] ||
		die "misc cannot be a grow-to-end partition"
	misc_bytes=$((PARTITION_SIZE[misc] * 512))
	[ "$misc_bytes" -ge $((FACTORY_RESET_FLAG_OFFSET + FACTORY_RESET_FLAG_BYTES)) ] ||
		die "misc partition is too small for the factory-reset flag"
	FACTORY_RESET_MISC_IMAGE=$(mktemp \
		"${TMPDIR:-/tmp}/recamera-factory-reset-misc.XXXXXX.img") ||
		die "could not allocate the factory-reset misc image"
	dd if=/dev/zero of="$FACTORY_RESET_MISC_IMAGE" bs=512 \
		count="${PARTITION_SIZE[misc]}" status=none ||
		die "could not initialize the factory-reset misc image"
	cmp -n "$misc_bytes" -- "$FACTORY_RESET_MISC_IMAGE" /dev/zero \
		>/dev/null 2>&1 ||
		die "factory-reset misc image initialization verification failed"
	printf '%s' "$FACTORY_RESET_FLAG" |
		dd of="$FACTORY_RESET_MISC_IMAGE" bs=1 \
			seek="$FACTORY_RESET_FLAG_OFFSET" conv=notrunc status=none ||
		die "could not write the factory-reset misc flag"
	flag_text=$(dd if="$FACTORY_RESET_MISC_IMAGE" bs=1 \
		skip="$FACTORY_RESET_FLAG_OFFSET" count="$FACTORY_RESET_FLAG_BYTES" \
		status=none | tr -d '\000')
	[ "$flag_text" = "$FACTORY_RESET_FLAG" ] ||
		die "factory-reset misc flag verification failed"
	validate_partition_image misc "$FACTORY_RESET_MISC_IMAGE"
	sync "$FACTORY_RESET_MISC_IMAGE" ||
		die "could not synchronize the factory-reset misc image"
}

flash_partition()
{
	local name="$1"
	local image="$2"
	validate_partition_image "$name" "$image"
	run_upgrade_tool WL "${PARTITION_OFFSET[$name]}" \
		"${PARTITION_SIZE[$name]}" "$image"
}

enter_download_mode()
{
	[ -f "$LOADER" ] && [ ! -L "$LOADER" ] ||
		die "missing regular download loader: $LOADER"
	if [ "$DRY_RUN" = 1 ]; then
		printf '%s\n' \
			'rkflash: dry-run: device probe skipped (Loader writes directly; Maskrom uses DownloadBoot first)'
		return 0
	fi
	[ -x "$UPGRADETOOL" ] || die "upgrade_tool is not executable: $UPGRADETOOL"
	require_single_device_mode
	case "$DEVICE_MODE" in
		Loader)
			printf 'rkflash: device already in Loader mode\n'
			;;
		Maskrom)
			run_upgrade_tool DB "$LOADER"
			wait_for_loader_mode
			;;
	esac
}

flash_system_set()
{
	local include_misc="$1"
	local misc_image=${2:-}
	local name image
	local -a selected=()

	for name in "${PARTITION_ORDER[@]}"; do
		case "$name" in
			userdata) continue ;;
			misc)
				[ "$include_misc" = 1 ] || continue
				;;
		esac
		if [ "$name" = misc ] && [ -n "$misc_image" ]; then
			image=$misc_image
		else
			image="$ROCKDEV_DIR/$name.img"
		fi
		validate_partition_image "$name" "$image"
		selected+=("$name")
	done
	[ "${#selected[@]}" -gt 0 ] || die "no system partition images selected"
	enter_download_mode
	for name in "${selected[@]}"; do
		if [ "$name" = misc ] && [ -n "$misc_image" ]; then
			image=$misc_image
		else
			image="$ROCKDEV_DIR/$name.img"
		fi
		flash_partition "$name" "$image"
	done
	run_upgrade_tool RD
}

main()
{
	local action=${1:-all}
	local image_spec image

	case "$action" in
		-h|--help|help)
			usage
			return 0
			;;
		rd)
			if [ "$DRY_RUN" != 1 ]; then
				[ -x "$UPGRADETOOL" ] ||
					die "upgrade_tool is not executable: $UPGRADETOOL"
			fi
			run_upgrade_tool RD
			return 0
			;;
		loader)
			image=${2:-$LOADER}
			[ -f "$image" ] && [ ! -L "$image" ] ||
				die "missing regular loader image: $image"
			if [ "$DRY_RUN" != 1 ]; then
				[ -x "$UPGRADETOOL" ] ||
					die "upgrade_tool is not executable: $UPGRADETOOL"
			fi
			run_upgrade_tool UL "$image"
			return 0
			;;
		update)
			image=${2:-$UPDATE_IMAGE}
			[ -f "$image" ] && [ ! -L "$image" ] ||
				die "missing regular update image: $image"
			if [ "$DRY_RUN" != 1 ]; then
				[ -x "$UPGRADETOOL" ] ||
					die "upgrade_tool is not executable: $UPGRADETOOL"
			fi
			printf '%s\n' \
				'rkflash: WARNING: UpgradeFirmware userdata behavior must be validated on your device.' >&2
			run_upgrade_tool UF "$image"
			return 0
			;;
		erase)
			[ "${2:-}" = I-UNDERSTAND-THIS-ERASES-THE-DEVICE ] ||
				die "erase requires the exact confirmation phrase shown by --help"
			[ -f "$LOADER" ] && [ ! -L "$LOADER" ] ||
				die "missing regular download loader: $LOADER"
			if [ "$DRY_RUN" != 1 ]; then
				[ -x "$UPGRADETOOL" ] ||
					die "upgrade_tool is not executable: $UPGRADETOOL"
			fi
			run_upgrade_tool EF "$LOADER"
			return 0
			;;
	esac

	image_spec=$(partition_spec_from_env)
	verify_active_board_layout "$image_spec"
	parse_partition_spec "$image_spec"
	case "$action" in
		all|system)
			printf '%s\n' \
				'rkflash: flashing system partitions; preserving misc and userdata'
			flash_system_set 0
			;;
		factory-reset)
			printf '%s\n' \
				'rkflash: factory-reset selected; normal rootfs will format userdata' >&2
			verify_factory_reset_target
			prepare_factory_reset_misc
			flash_system_set 1 "$FACTORY_RESET_MISC_IMAGE"
			;;
		userdata)
			die "userdata is grow-to-end and has no image; use factory-reset explicitly"
		;;
		*)
			image=${2:-$ROCKDEV_DIR/$action.img}
			validate_partition_image "$action" "$image"
			enter_download_mode
			flash_partition "$action" "$image"
			run_upgrade_tool RD
			;;
	esac
}

main "$@"
