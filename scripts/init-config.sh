#!/bin/sh
set -eu

config_path="${XRAY_CONFIG_PATH:-config/config.json}"

printf 'Initializing Xray config at %s\n' "$config_path"

if [ ! -f scripts/render-config.mjs ]; then
  printf 'Config init failed: scripts/render-config.mjs was not found.\n' >&2
  exit 1
fi

node scripts/render-config.mjs

if [ ! -f "$config_path" ]; then
  printf 'Config init failed: %s was not created.\n' "$config_path" >&2
  exit 1
fi

if [ ! -s "$config_path" ]; then
  printf 'Config init failed: %s is empty.\n' "$config_path" >&2
  exit 1
fi

printf 'Config init complete: %s\n' "$config_path"
