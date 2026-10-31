#!/usr/bin/env bash
# Shared helpers. Dotenv values are read as data, never evaluated as shell commands.

read_env() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  awk -v wanted="$key" '
    /^[[:space:]]*#/ { next }
    {
      pos = index($0, "="); if (!pos) next
      key = substr($0, 1, pos - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key != wanted) next
      value = substr($0, pos + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      first = substr(value, 1, 1); last = substr(value, length(value), 1)
      if (length(value) >= 2 && first == last && (first == "\047" || first == "\042"))
        value = substr(value, 2, length(value) - 2)
      else sub(/[[:space:]]+#.*$/, "", value)
      result = value
    }
    END { printf "%s", result }
  ' "$file"
}

write_env_value() {
  local key="$1" value="$2"
  case "$value" in
    *"'"*|*$'\n'*|*$'\r'*) printf 'Unsupported characters in %s\n' "$key" >&2; return 1 ;;
  esac
  printf "%s='%s'\n" "$key" "$value"
}

compose() {
  docker compose -f docker-compose.yml -f docker-compose.https.yml "$@"
}

curl_quote() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

verify_https_proxy() (
  set -eu
  local proxy="$1" certificate="$2" credentials="$3" attempts="${4:-3}"
  local work username password attempt=1
  work="$(mktemp -d "${TMPDIR:-/tmp}/xray-verify.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  chmod 700 "$work"
  username="$(read_env PROXY_USERNAME "$credentials")"
  password="$(read_env PROXY_PASSWORD "$credentials")"
  {
    printf 'proxy = "%s"\n' "$(curl_quote "$proxy")"
    printf 'proxy-cacert = "%s"\n' "$(curl_quote "$certificate")"
    printf 'noproxy = ""\n'
  } > "$work/curl.conf"
  chmod 600 "$work/curl.conf"
  # HTTP CONNECT authentication is checked independently of upstream availability.
  curl --config "$work/curl.conf" --silent --show-error --connect-timeout 10 --max-time 15 \
    --output /dev/null --write-out '%{http_connect}' https://telegram.org/ \
    > "$work/auth-status" 2> "$work/auth-error" || true
  if [ "$(cat "$work/auth-status")" != 407 ]; then
    printf 'FAIL: unauthenticated HTTPS proxy did not return HTTP 407.\n' >&2
    cat "$work/auth-error" >&2
    return 1
  fi
  printf 'Authentication check passed: unauthenticated CONNECT rejected (407).\n'
  printf 'proxy-user = "%s:%s"\n' "$(curl_quote "$username")" "$(curl_quote "$password")" >> "$work/curl.conf"
  while [ "$attempt" -le "$attempts" ]; do
    if curl --config "$work/curl.conf" --silent --show-error --connect-timeout 10 --max-time 30 \
      --output "$work/body" --write-out '%{http_code}' https://telegram.org/ \
      > "$work/status" 2> "$work/error" &&
      [ "$(cat "$work/status")" = 200 ] &&
      sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p' "$work/body" | grep -q Telegram; then
      printf 'HTTPS proxy test passed: HTTP 200; '
      sed -n 's/.*<title>\([^<]*\)<\/title>.*/title: \1/p' "$work/body"
      return 0
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -le "$attempts" ]; then sleep 5; fi
  done
  printf 'FAIL: Telegram request through %s failed.\n' "$proxy" >&2
  cat "$work/error" >&2
  return 1
)
