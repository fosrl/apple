#!/usr/bin/env bash
# Reset Pangolin client settings (DNS, MTU, and related preferences).
# Quit Pangolin before running this script.

set -e

BUNDLE_ID="net.pangolin.Pangolin"
CONFIG_FILE="pangolin.json"

DEFAULT_CONFIG='{
  "dnsOverrideEnabled": true,
  "dnsTunnelEnabled": false
}'

echo "Resetting Pangolin client settings (DNS, MTU, etc.)..."

write_default_config() {
  local config_path="$1"
  printf '%s\n' "$DEFAULT_CONFIG" > "$config_path"
  echo "  Wrote defaults to $config_path"
}

clear_config_at() {
  local label="$1"
  local dir="$2"
  local config_path="$dir/$CONFIG_FILE"

  if [[ ! -f "$config_path" && ! -d "$dir" ]]; then
    return 0
  fi

  echo "Clearing settings ($label)..."
  mkdir -p "$dir"
  rm -f "$config_path"
  write_default_config "$config_path"
}

# Standard Application Support (non-sandboxed or when running from Xcode)
clear_config_at "Application Support" "$HOME/Library/Application Support/Pangolin"

# Sandboxed app container (if present)
clear_config_at "sandbox container" \
  "$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/Pangolin"

echo "Done. Restart Pangolin to pick up the reset settings."
