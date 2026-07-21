#!/usr/bin/env bash
set -eu

TARGET_URL="${TARGET_URL:-https://telegram.org}"
TARGET_CONNECT_HOST="telegram.org"
TARGET_CONNECT_PORT="443"
PROXY_URL="${PROXY_URL:-http://xray:8080}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
MAX_TIME="${MAX_TIME:-30}"
MAX_REDIRS="${MAX_REDIRS:-5}"
VLESS_URI="${VLESS_URI:-}"
VLESS_SERVER_ADDRESS="${VLESS_SERVER_ADDRESS:-}"
VLESS_SERVER_PORT="${VLESS_SERVER_PORT:-}"
SELF_ROUTE_CHECK="${SELF_ROUTE_CHECK:-auto}"
DIRECT_IP_URL="${DIRECT_IP_URL:-https://api.ipify.org}"
SELF_ROUTE_CONNECT_TIMEOUT="${SELF_ROUTE_CONNECT_TIMEOUT:-5}"
SELF_ROUTE_MAX_TIME="${SELF_ROUTE_MAX_TIME:-5}"

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

proxy_host_from_url() {
  without_scheme="${1#*://}"
  without_auth="${without_scheme#*@}"
  host_port="${without_auth%%/*}"

  case "$host_port" in
    \[*\]*)
      host="${host_port#\[}"
      host="${host%%\]*}"
      ;;
    *)
      host="${host_port%%:*}"
      ;;
  esac

  printf '%s' "$host"
}

strip_optional_quotes() {
  value="$1"
  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac
  printf '%s' "$value"
}

parse_vless_uri_host() {
  uri="$(strip_optional_quotes "$1")"
  case "$uri" in
    vless://*@*)
      without_scheme="${uri#vless://}"
      without_auth="${without_scheme#*@}"
      authority="${without_auth%%[/?#]*}"
      case "$authority" in
        \[*\]*)
          host="${authority#\[}"
          host="${host%%\]*}"
          ;;
        *)
          host="${authority%%:*}"
          ;;
      esac
      printf '%s' "$host"
      ;;
  esac
}

parse_vless_uri_port() {
  uri="$(strip_optional_quotes "$1")"
  case "$uri" in
    vless://*@*)
      without_scheme="${uri#vless://}"
      without_auth="${without_scheme#*@}"
      authority="${without_auth%%[/?#]*}"
      case "$authority" in
        \[*\]:*)
          port="${authority##*:}"
          ;;
        *:*)
          port="${authority##*:}"
          ;;
        *)
          port=""
          ;;
      esac
      printf '%s' "$port"
      ;;
  esac
}

host_for_url() {
  case "$1" in
    *:*) printf '[%s]' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

bool_is_false() {
  case "$1" in
    0|false|False|FALSE|no|No|NO|off|Off|OFF) return 0 ;;
    *) return 1 ;;
  esac
}

bool_is_true() {
  case "$1" in
    1|true|True|TRUE|yes|Yes|YES|on|On|ON) return 0 ;;
    *) return 1 ;;
  esac
}

single_line() {
  printf '%s' "$1" | tr -d '\r' | sed -n '1s/[[:space:]]*$//p'
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
      proxy_host="$(proxy_host_from_url "$PROXY_URL")"
      case "$proxy_host" in
        xray|xray-proxy)
          printf 'Proxy DNS resolution failed for "%s". Docker service names only resolve inside the Compose network; run this test with "docker compose -f docker-compose.yml -f docker-compose.test.yml run --rm telegram-proxy-test", or publish the proxy port and set PROXY_URL to a host-reachable address such as http://127.0.0.1:8080.' "$proxy_host"
          ;;
        *)
          printf 'Proxy DNS resolution failed. The test environment could not resolve the proxy host from PROXY_URL.'
          ;;
      esac
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

fetch_direct_egress_ip() {
  set +e
  result=$(
    HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= NO_PROXY= \
    http_proxy= https_proxy= all_proxy= no_proxy= \
    curl \
      --silent \
      --show-error \
      --connect-timeout "$SELF_ROUTE_CONNECT_TIMEOUT" \
      --max-time "$SELF_ROUTE_MAX_TIME" \
      --noproxy "*" \
      "$DIRECT_IP_URL" \
      2>"$self_route_log"
  )
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    single_line "$result"
  fi
}

join_lines() {
  printf '%s' "$1" | tr '\n' ',' | sed 's/,$//'
}

resolve_vless_server_ips() {
  server_host="$1"

  if command -v getent >/dev/null 2>&1; then
    set +e
    result="$(getent hosts "$server_host" 2>"$self_route_log")"
    status=$?
    set -e

    if [ "$status" -eq 0 ] && [ -n "$result" ]; then
      printf '%s\n' "$result" | sed -n 's/[[:space:]].*$//p' | sed '/^$/d'
      return
    fi
  fi

  server_port="$2"
  url_host="$(host_for_url "$server_host")"

  set +e
  result=$(
    HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= NO_PROXY= \
    http_proxy= https_proxy= all_proxy= no_proxy= \
    curl \
      --silent \
      --show-error \
      --connect-timeout "$SELF_ROUTE_CONNECT_TIMEOUT" \
      --max-time "$SELF_ROUTE_MAX_TIME" \
      --noproxy "*" \
      --output /dev/null \
      --write-out 'remote_ip=%{remote_ip}
' \
      "telnet://$url_host:$server_port" \
      2>"$self_route_log"
  )
  set -e

  printf '%s\n' "$result" | sed -n 's/^remote_ip=//p' | sed -n '1p'
}

run_self_route_check() {
  if bool_is_false "$SELF_ROUTE_CHECK"; then
    printf 'Self-route check: disabled\n'
    return
  fi

  vless_host="$VLESS_SERVER_ADDRESS"
  vless_port="$VLESS_SERVER_PORT"

  if [ -z "$vless_host" ] && [ -n "$VLESS_URI" ]; then
    vless_host="$(parse_vless_uri_host "$VLESS_URI")"
  fi

  if [ -z "$vless_port" ] && [ -n "$VLESS_URI" ]; then
    vless_port="$(parse_vless_uri_port "$VLESS_URI")"
  fi

  if [ -z "$vless_host" ] || [ -z "$vless_port" ]; then
    if bool_is_true "$SELF_ROUTE_CHECK"; then
      printf 'FAIL: SELF_ROUTE_CHECK=true, but VLESS_URI or VLESS_SERVER_ADDRESS/VLESS_SERVER_PORT was not provided.\n'
      exit 8
    fi

    printf 'Self-route check: skipped (VLESS server address not provided)\n'
    return
  fi

  printf 'Self-route check: checking Docker egress and VLESS server route\n'

  direct_ip="$(fetch_direct_egress_ip)"
  if [ -z "$direct_ip" ]; then
    if bool_is_true "$SELF_ROUTE_CHECK"; then
      printf 'FAIL: Could not determine direct Docker egress IP from %s.\n' "$DIRECT_IP_URL"
      exit 8
    fi

    printf 'Self-route check: warning: could not determine direct Docker egress IP; continuing\n'
    return
  fi

  printf 'Self-route check: direct Docker egress is %s; resolving %s\n' "$direct_ip" "$vless_host"

  server_ips="$(resolve_vless_server_ips "$vless_host" "$vless_port")"
  if [ -z "$server_ips" ]; then
    if bool_is_true "$SELF_ROUTE_CHECK"; then
      printf 'FAIL: Could not resolve or reach VLESS server %s:%s for the self-route check.\n' "$vless_host" "$vless_port"
      exit 8
    fi

    printf 'Self-route check: warning: could not resolve VLESS server %s:%s; continuing\n' "$vless_host" "$vless_port"
    return
  fi

  server_ips_display="$(join_lines "$server_ips")"

  if printf '%s\n' "$server_ips" | grep -F -x "$direct_ip" >/dev/null 2>&1; then
    printf 'FAIL: Docker direct egress IP (%s) matches the VLESS server IP for %s:%s.\n' "$direct_ip" "$vless_host" "$vless_port"
    printf 'This usually means the host VPN/V2box route is tunneling Docker traffic through the same VLESS server, so Dockerized Xray dials back into its own upstream path.\n'
    printf 'Disable V2box while testing, or add DIRECT/bypass rules for %s and %s, restart Docker Desktop, then rerun this test.\n' "$vless_host" "$server_ips_display"
    exit 8
  fi

  printf 'Self-route check: VLESS server %s resolves to %s; no routing loop detected\n' "$vless_host" "$server_ips_display"
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
self_route_log="$(mktemp "$tmp_dir/telegram-proxy-route.XXXXXX")"
cleanup() {
  rm -f "$verbose_log" "$self_route_log"
}
trap cleanup EXIT HUP INT TERM

printf 'Telegram proxy test\n'
printf 'Target URL: %s\n' "$TARGET_URL"
printf 'Proxy URL: %s\n' "$(redact_proxy_url "$PROXY_URL")"
printf 'Connect timeout: %ss\n' "$CONNECT_TIMEOUT"
printf 'Request timeout: %ss\n' "$MAX_TIME"
run_self_route_check
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
