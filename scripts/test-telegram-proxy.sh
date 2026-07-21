#!/usr/bin/env bash
set -eu

TARGET_URL="${TARGET_URL:-https://telegram.org}"
TARGET_CONNECT_HOST="telegram.org"
TARGET_CONNECT_PORT="443"
PROXY_URL="${PROXY_URL:-http://xray:8080}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
MAX_TIME="${MAX_TIME:-30}"
MAX_REDIRS="${MAX_REDIRS:-5}"

usage_error() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 2
}

redact_proxy_url() {
  case "$1" in
    *://*@*)
      scheme="${1%%://*}"
      rest="${1#*://}"
      after_at="${rest#*@}"
      printf '%s://***:***@%s' "$scheme" "$after_at"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

has_embedded_proxy_credentials() {
  case "$PROXY_URL" in
    *://*@*) return 0 ;;
    *) return 1 ;;
  esac
}

print_diagnostic_tail() {
  printf '\nCurl diagnostic tail:\n'
  sed \
    -e 's/Proxy-Authorization:.*/Proxy-Authorization: <redacted>/' \
    -e 's/proxy-authorization:.*/proxy-authorization: <redacted>/' \
    "$verbose_log" | tail -n "${VERBOSE_TAIL_LINES:-25}" || true
}

explain_curl_exit() {
  case "$1" in
    5)
      printf 'Proxy DNS resolution failed. The test container could not resolve the proxy host from PROXY_URL.'
      ;;
    6)
      printf 'DNS resolution failed. With socks5h, this can mean proxy-side DNS failed for the target host.'
      ;;
    7)
      printf 'The proxy is unreachable or refused the TCP connection.'
      ;;
    28)
      printf 'The request timed out.'
      ;;
    35|51|58|60|77)
      printf 'TLS negotiation or certificate verification failed.'
      ;;
    47)
      printf 'Too many redirects were returned.'
      ;;
    52|55|56)
      printf 'The connection failed while sending or receiving data through the proxy.'
      ;;
    97)
      printf 'The proxy handshake failed. Check proxy type, credentials, and whether the selected port is HTTP or SOCKS5.'
      ;;
    *)
      printf 'curl failed with exit code %s.' "$1"
      ;;
  esac
}

case "$PROXY_URL" in
  http://*|https://*|socks5h://*)
    ;;
  socks5://*)
    usage_error 'Use socks5h:// for SOCKS5 tests so DNS resolution happens through the proxy.'
    ;;
  *)
    usage_error 'PROXY_URL must start with http://, https://, or socks5h://.'
    ;;
esac

proxy_auth=""
if ! has_embedded_proxy_credentials; then
  proxy_username="${PROXY_USERNAME:-}"
  proxy_password="${PROXY_PASSWORD:-}"

  if [ -n "$proxy_username" ] || [ -n "$proxy_password" ]; then
    if [ -z "$proxy_username" ] || [ -z "$proxy_password" ]; then
      usage_error 'Set both PROXY_USERNAME and PROXY_PASSWORD, or embed credentials in PROXY_URL.'
    fi

    proxy_auth="$proxy_username:$proxy_password"
  fi
fi

tmp_dir="${TMPDIR:-/tmp}"
verbose_log="$(mktemp "$tmp_dir/telegram-proxy-curl.XXXXXX")"
cleanup() {
  rm -f "$verbose_log"
}
trap cleanup EXIT HUP INT TERM

printf 'Telegram proxy test\n'
printf 'Target URL: %s\n' "$TARGET_URL"
printf 'Proxy URL: %s\n' "$(redact_proxy_url "$PROXY_URL")"
printf 'Connect timeout: %ss\n' "$CONNECT_TIMEOUT"
printf 'Request timeout: %ss\n' "$MAX_TIME"
printf '\n'

set +e
if [ -n "$proxy_auth" ]; then
  curl_output=$(
    HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= NO_PROXY= \
    http_proxy= https_proxy= all_proxy= no_proxy= \
    curl \
      --silent \
      --show-error \
      --verbose \
      --location \
      --max-redirs "$MAX_REDIRS" \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --max-time "$MAX_TIME" \
      --noproxy "" \
      --proxy "$PROXY_URL" \
      --proxy-user "$proxy_auth" \
      --output /dev/null \
      --write-out 'http_code=%{http_code}
time_total=%{time_total}
url_effective=%{url_effective}
' \
      "$TARGET_URL" \
      2>"$verbose_log"
  )
else
  curl_output=$(
    HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= NO_PROXY= \
    http_proxy= https_proxy= all_proxy= no_proxy= \
    curl \
      --silent \
      --show-error \
      --verbose \
      --location \
      --max-redirs "$MAX_REDIRS" \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --max-time "$MAX_TIME" \
      --noproxy "" \
      --proxy "$PROXY_URL" \
      --output /dev/null \
      --write-out 'http_code=%{http_code}
time_total=%{time_total}
url_effective=%{url_effective}
' \
      "$TARGET_URL" \
      2>"$verbose_log"
  )
fi
curl_exit=$?
set -e

http_code="$(printf '%s\n' "$curl_output" | sed -n 's/^http_code=//p')"
duration="$(printf '%s\n' "$curl_output" | sed -n 's/^time_total=//p')"
effective_url="$(printf '%s\n' "$curl_output" | sed -n 's/^url_effective=//p')"

http_code="${http_code:-000}"
duration="${duration:-0.000000}"
effective_url="${effective_url:-unknown}"

printf 'HTTP status: %s\n' "$http_code"
printf 'Total duration: %ss\n' "$duration"
printf 'Effective URL: %s\n' "$effective_url"

case "$PROXY_URL" in
  http://*|https://*)
    if grep -E "(^> CONNECT ${TARGET_CONNECT_HOST}:${TARGET_CONNECT_PORT} |Establish HTTP proxy tunnel to ${TARGET_CONNECT_HOST}:${TARGET_CONNECT_PORT}|CONNECT tunnel)" "$verbose_log" >/dev/null 2>&1; then
      proxy_evidence="HTTP CONNECT tunnel"
    else
      proxy_evidence=""
    fi
    ;;
  socks5h://*)
    if grep -E "(SOCKS5.*${TARGET_CONNECT_HOST}(:| port )${TARGET_CONNECT_PORT}|SOCKS5.*remotely resolved|Opened SOCKS connection .* to ${TARGET_CONNECT_HOST} port ${TARGET_CONNECT_PORT})" "$verbose_log" >/dev/null 2>&1; then
      proxy_evidence="SOCKS5H remote DNS connection"
    else
      proxy_evidence=""
    fi
    ;;
  *)
    proxy_evidence=""
    ;;
esac

if [ -n "$proxy_evidence" ]; then
  printf 'Proxy path: confirmed via %s\n' "$proxy_evidence"
else
  printf 'Proxy path: not confirmed\n'
fi

if [ "$curl_exit" -ne 0 ]; then
  printf 'FAIL: '
  explain_curl_exit "$curl_exit"
  printf '\n'
  print_diagnostic_tail
  exit "$curl_exit"
fi

case "$http_code" in
  [0-9][0-9][0-9])
    ;;
  *)
    printf 'FAIL: curl did not return a valid HTTP status code.\n'
    print_diagnostic_tail
    exit 3
    ;;
esac

if [ -z "$proxy_evidence" ]; then
  printf 'FAIL: curl succeeded, but proxy usage could not be confirmed from curl diagnostics.\n'
  print_diagnostic_tail
  exit 4
fi

if [ "$http_code" -ge 200 ] && [ "$http_code" -le 399 ]; then
  printf 'SUCCESS: Telegram request succeeded through the proxy.\n'
  exit 0
fi

printf 'FAIL: Telegram returned unsuccessful HTTP status %s.\n' "$http_code"
exit 5
