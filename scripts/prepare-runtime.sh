#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/deployment-common.sh

config=config/config.json
work="$(mktemp -d "${TMPDIR:-/tmp}/xray-config.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Keep the existing config inode, group and mode: Xray runs without root privileges.
jq -e '.inbounds[] | select(.tag == "http-in") |
  ((.settings.users // .settings.accounts // []) | length) > 0' "$config" > /dev/null || {
  printf 'Refusing to publish a proxy without authentication.\n' >&2
  exit 1
}
jq '
  (.inbounds[] | select(.tag == "http-in")) as $http |
  .inbounds = ([.inbounds[] | select(.tag != "https-in")] + [
    ($http | .tag = "https-in" | .port = 8443 |
      .streamSettings = {security: "tls", tlsSettings: {
        minVersion: "1.2", alpn: ["http/1.1"], certificates: [{
          certificateFile: "/run/xray-tls/server.crt",
          keyFile: "/run/xray-tls/server.key"
        }]
      }})
  ]) |
  (.routing.rules[] | select((.inboundTag // []) | index("http-in")) |
    .inboundTag) |= (. + ["https-in"] | unique)
' "$config" > "$work/config.json"
cat "$work/config.json" > "$config"

removed=0
while :; do
  if compose run --rm --no-deps xray run -test -config /usr/local/etc/xray/config.json \
    > "$work/validation.log" 2>&1; then
    printf 'Core validation passed: %s nodes; %s rejected nodes skipped.\n' \
      "$(jq '.outbounds | length' "$config")" "$removed"
    break
  fi
  tag="$(sed -n 's/.*failed to build outbound config with tag \(proxy-[0-9][0-9]*\) >.*/\1/p' \
    "$work/validation.log" | head -n 1)"
  if [ -z "$tag" ] || ! jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$config" > /dev/null; then
    printf 'Xray validation failed; inspect the runtime config with xray run -test.\n' >&2
    tail -n 12 "$work/validation.log" >&2
    exit 1
  fi
  printf 'Skipping %s: rejected by the installed Xray core.\n' "$tag"
  jq --arg tag "$tag" '.outbounds |= map(select(.tag != $tag))' "$config" > "$work/config.json"
  jq -e '.outbounds | length > 0' "$work/config.json" > /dev/null || {
    printf 'No compatible subscription nodes remain.\n' >&2
    exit 1
  }
  cat "$work/config.json" > "$config"
  removed=$((removed + 1))
done
