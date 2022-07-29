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

luks_unlock() {
  local luks_device="$1"
  local device_name="$2"
  local key_slot="$3"
  # local password="$4"

  if [[ ! -b "$luks_device" ]]
  then
    echo "LUKS device does not exist: $luks_device" >&2
    return 2
  fi

  if [[ -b "/dev/mapper/${device_name}" ]]
  then
    echo "✅ Already unlocked"
    return 0
  fi

  local extra_args=()
  if [[ -n "$key_slot" && "$key_slot" != null ]]
  then
    extra_args+=(--key-slot "$key_slot")
  fi

  if ! sudo cryptsetup luksOpen "${extra_args[@]}" "${luks_device}" "${device_name}"
  then
    echo "Failed to unlock." >&2
    return 1
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

mount_share() {
  local config_path="$1"
  local device name mountpoint

  device="$(config_get "${config_path}.device")"
  name="$(config_get "${config_path}.name")"
  mountpoint="$(config_get "${config_path}.mountpoint")"

  if mount | grep -q "${device} on ${mountpoint}"
  then
    echo "✅ Already mounted: ${name}"
    return
  fi

  echo "⛰️  Mounting ${device} on ${mountpoint}..."

  if ! interval=5 retry sudo mount "${device}" "${mountpoint}"
  then
    echo "❌Mount failed for ${device_name}" >&2
    return 1
  fi

  echo "✅ Mounted: ${device_name}"
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

callback_exec() {
  local device_config="$1"
  local -a callbacks

  mapfile -t callbacks < <(config_get ".${device_config}.callback[]" 2>/dev/null)

  for callback in "${callbacks[@]}"
  do
    echo "⚡Executing \"$callback\"..."
    sh -c "$callback"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
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
      *)
        break
        ;;
    esac
  done

  declare -i RC=0

  for DEVICE in $(config_keys)
  do
    if ! magic_mount "${DEVICE}"
    then
      RC=1
    else
      callback_exec "${DEVICE}"
    fi
  done

  exit "$RC"
fi
