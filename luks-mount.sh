#!/usr/bin/env bash

usage() {
  echo "Usage: $(basename "$0") [--config CONFIG]"
}

retry() {
  local -i interval=${interval:-10}
  local -i max_retries=${max_retries:-3}
  # local -i max_runtime=30

  local cmd=("$@")

  local tries

  until "${cmd[@]}"
  do
    if [[ "$tries" -ge "$max_retries" ]]
    then
      echo "Giving up on ${cmd[*]} after $tries tries." >&2
      return 1
    fi

    (( tries++ ))
    sleep "$interval"
  done
}

# shellcheck disable=2120
config_keys() {
  config_get "${*:-.} | keys" | sed 's/^- //'
}

config_get() {
  local config_dir config_file
  local global_config=/etc/luks-mount.yaml

  if [[ -n "$CONFIG_FILE" && -r "$CONFIG_FILE" ]]
  then
    config_file="$CONFIG_FILE"
  elif [[ -r "$global_config" ]]
  then
    config_file="$global_config"
  else
    config_dir="$(cd "$(dirname "$0")" >/dev/null 2>&1 || return 1; pwd -P)"
    config_file="${config_dir}/config.yaml"
  fi

  yq --exit-status --no-colors --no-doc \
    eval "$*" "${config_file}"
}

config_get_callback() {
  local type="$1"
  local device_config="$2"

  config_get ".${device_config}.callbacks" 2>/dev/null | \
    yq --exit-status --no-colors --no-doc ".${type}[]" 2>/dev/null
}

callback_exec() {
  local type="$1"
  local device_config="$2"

  local callbacks
  mapfile -t callbacks < <(config_get_callback "$type" "$device_config")

  if [[ "${#callbacks[@]}" -gt 0 ]]
  then
    local cmd
    for cmd in "${callbacks[@]}"
    do
      echo "🪄 Executing $type callback: \$ $cmd" >&2
      sh -c "${cmd}"
    done
  fi
}

luks_device_unlocked() {
  local luks_device="$1"
  local device_name="$2"

  if [[ ! -b "$luks_device" ]]
  then
    echo "LUKS device does not exist: $luks_device" >&2
    return 2
  fi

  if [[ -b "/dev/mapper/${device_name}" ]]
  then
    echo "✅ Already unlocked: $device_name ($luks_device)"
    return 0
  fi

  # Device not unlocked yet.
  return 1
}

luks_unlock() {
  local luks_device="$1"
  local device_name="$2"
  local key_slot="$3"

  local passphrase_var passphrase
  passphrase_var="$(tr '[:lower:]' '[:upper:]' <<< "LUKS_PASSPHRASE_${device_name//-/_}")"

  if [[ -v "${passphrase_var}" ]]
  then
    passphrase="${!passphrase_var}"
    echo "LUKS passphrase for $luks_device provided by environment variable $passphrase_var." >&2
  fi

  luks_device_unlocked "$luks_device" "$device_name"
  local rc="$?"

  if [[ "$rc" != 1 ]]
  then
    return "$rc"
  fi

  local extra_args=()
  if [[ -n "$key_slot" && "$key_slot" != null ]]
  then
    extra_args+=(--key-slot "$key_slot")
  fi

  if [[ -n "$passphrase" ]]
  then
    # Use provided passphrase
    if ! printf '%s' "$passphrase" | sudo cryptsetup luksOpen "${extra_args[@]}" "${luks_device}" "${device_name}"
    then
      echo "Failed to unlock LUKS device ${luks_device}." >&2
      return 1
    fi
  else
    # Interactive passphrase prompt
    if ! sudo cryptsetup luksOpen "${extra_args[@]}" "${luks_device}" "${device_name}"
    then
      echo "Failed to unlock LUKS device ${luks_device}." >&2
      return 1
    fi
  fi

  echo "✅ Unlocked. Waiting for ${device_name}..."

  if retry test -b "/dev/mapper/${device_name}"
  then
    echo "✅ Device ${device_name} appeared"
    return 0
  else
    echo "❌ Failed to unlock device" >&2
    return 1
  fi
}

luks_lock() {
  local luks_device="$1"
  local device_name="$2"

  luks_device_unlocked "$luks_device" "$device_name"
  local rc="$?"

  if [[ "$rc" == 1 ]]
  then
    echo "✅ $device_name: LUKS device $luks_device is already locked."
    return 0
  fi

  if ! sudo cryptsetup luksClose "${device_name}"
  then
    echo "❌ Failed to lock ${device_name} (${luks_device})." >&2
    return 1
  fi

  echo "✅ Locked."
}

share_is_mounted() {
  local device="$1" name="$2" mountpoint="$3"

  if mount | grep -q "${device} on ${mountpoint}"
  then
    echo "✅ Already mounted: ${name} on ${mountpoint}"
    return
  fi

  # Share not mounted
  return 1
}

mount_share() {
  local config_path="$1"
  local device name mountpoint

  device="$(config_get "${config_path}.device")"
  name="$(config_get "${config_path}.name")"
  mountpoint="$(config_get "${config_path}.mountpoint")"

  if share_is_mounted "$device" "$name" "$mountpoint"
  then
    return
  fi

  echo "⛰️  Mounting ${device} on ${mountpoint}..."

  if ! interval=5 retry sudo mount "${device}" "${mountpoint}"
  then
    echo "❌Mount failed for ${name}" >&2
    return 1
  fi

  echo "✅ Mounted: ${name}"
  return
}

umount_share() {
  local config_path="$1"
  local device name mountpoint

  device="$(config_get "${config_path}.device")"
  name="$(config_get "${config_path}.name")"
  mountpoint="$(config_get "${config_path}.mountpoint")"

  if ! share_is_mounted "$device" "$name" "$mountpoint"
  then
    echo "✅ Share is already unmounted: $device on $mountpoint ($name)" >&2
    return
  fi

  echo "⛰️  Unmounting ${device} from ${mountpoint}..."

  if ! interval=5 retry sudo umount --all-targets "${device}"
  then
    echo "❌Unmount failed for ${device_name}" >&2
    return 1
  fi

  echo "✅ Unmounted: ${name} ($device)"
  return
}

magic_mount() {
  local device_config="$1"
  local luks_device device_name luks_key_slot

  luks_device="$(config_get ".${device_config}.luks.device")"
  luks_key_slot="$(config_get ".${device_config}.luks.key_slot" 2>/dev/null)"
  device_name="$(config_get ".${device_config}.device.name")"

  if ! luks_unlock "$luks_device" "$device_name" "$luks_key_slot"
  then
    echo "❌Failed to unlock luks device $luks_device [${device_name}]" >&2
    return 1
  fi

  local -i rc=0
  local -i share_id
  for share_id in $(config_keys ".${device_config}.mounts")
  do
    if ! mount_share ".${device_config}.mounts.${share_id}"
    then
      rc=1
    fi
  done

  return "$rc"
}

magic_unmount() {
  local device_config="$1"
  local luks_device device_name luks_key_slot

  local -i rc=0
  local -i share_id
  for share_id in $(config_keys ".${device_config}.mounts")
  do
    if ! umount_share ".${device_config}.mounts.${share_id}"
    then
      rc=1
    fi
  done

  if [[ "$rc" == 0 ]]
  then
    callback_exec post_umount "${DEVICE}"
  else
    echo "⚠️ Skipping post_umount callbacks since some shares failed to unmount." >&2
  fi

  luks_device="$(config_get ".${device_config}.luks.device")"
  luks_key_slot="$(config_get ".${device_config}.luks.key_slot" 2>/dev/null)"
  device_name="$(config_get ".${device_config}.device.name")"

  if ! luks_lock "$luks_device" "$device_name" "$luks_key_slot"
  then
    rc=1
  fi

  return "$rc"
}

check_device() {
  local device_config="$1"
  local luks_device device_name

  luks_device="$(config_get ".${device_config}.luks.device")"
  device_name="$(config_get ".${device_config}.device.name")"

  if ! luks_device_unlocked "$luks_device" "$device_name"
  then
    echo "LUKS device ${luks_device} (${device_name}) not unlocked" >&2
    return 1
  fi

  local -i rc=0
  local -i share_id
  local config_path device name mountpoint

  for share_id in $(config_keys ".${device_config}.mounts")
  do
    config_path=".${device_config}.mounts.${share_id}"
    device="$(config_get "${config_path}.device")"
    name="$(config_get "${config_path}.name")"
    mountpoint="$(config_get "${config_path}.mountpoint")"

    if ! share_is_mounted "$device" "$name" "$mountpoint"
    then
      rc=1
    fi
  done

  return "$rc"
}


if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  ACTION="mount"

  while [[ -n "$*" ]]
  do
    case "$1" in
      help|h|-h|--help)
        usage
        exit 0
        ;;
      --config|-c)
        CONFIG_FILE="$2"
        shift 2
        ;;
      --force-callback|--fc)
        FORCE_CALLBACK=1
        shift
        ;;
      check|status)
        ACTION=check
        shift
        ;;
      umount|unmount)
        ACTION=umount
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  declare -i RC=0

  case "$ACTION" in
    check)
      for DEVICE in $(config_keys)
      do
        if ! check_device "${DEVICE}"
        then
          RC=1
        fi
      done
      ;;
    mount)
      for DEVICE in $(config_keys)
      do
        if check_device "$DEVICE" >/dev/null
        then
          echo "✅ Nothing to do for $DEVICE" >&2

          if [[ -n "$FORCE_CALLBACK" ]]
          then
            callback_exec post_mount "${DEVICE}"
          fi
          continue
        fi

        if ! magic_mount "${DEVICE}"
        then
          RC=1
        else
          callback_exec post_mount "${DEVICE}"
        fi
      done
      ;;
    umount)
      for DEVICE in $(config_keys)
      do
        if ! check_device "$DEVICE" >/dev/null
        then
          echo "✅ Nothing to do for $DEVICE" >&2
        fi

        callback_exec pre_lock "${DEVICE}"

        if ! magic_unmount "${DEVICE}"
        then
          RC=1
        else
          callback_exec post_lock "${DEVICE}"
        fi
      done
      ;;
    *)
      echo "Unknown action: $ACTION" >&2
      RC=2
      ;;
  esac

  exit "$RC"
fi
