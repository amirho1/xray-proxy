#!/usr/bin/env bash
# Run locally: bash scripts/deploy.sh [--rotate-password]
set -euo pipefail
umask 077
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source scripts/deployment-common.sh
case "${1:-}" in
  --help|-h)
    printf 'Usage: bash scripts/deploy.sh [--rotate-password]\nReads SSH_PROXY and SSH_PASSWORD from .env. Deploys an authenticated HTTPS proxy.\n'
    exit 0 ;;
  ''|--rotate-password) ;;
  *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
for tool in ssh openssl tar git curl awk; do command -v "$tool" > /dev/null || { printf 'Required: %s\n' "$tool" >&2; exit 1; }; done

target="${SSH_PROXY:-$(read_env SSH_PROXY .env)}"
ssh_password="${SSH_PASSWORD:-$(read_env SSH_PASSWORD .env)}"
[ -n "$target" ] && [ -n "$ssh_password" ] || {
  printf 'Set SSH_PROXY=root@IP and SSH_PASSWORD in .env.\n' >&2; exit 1
}
ip="${target##*@}"
if ! [[ "$target" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*@[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'SSH_PROXY must use user@IPv4 format. Set DEPLOY_SSH_PORT separately.\n' >&2; exit 1
fi
ssh_port="${DEPLOY_SSH_PORT:-$(read_env DEPLOY_SSH_PORT .env)}"; ssh_port="${ssh_port:-22}"
port="${HTTPS_PROXY_PORT:-$(read_env HTTPS_PROXY_PORT .env)}"; port="${port:-443}"
for number in "$ssh_port" "$port"; do
  [[ "$number" =~ ^[0-9]+$ ]] && [ "$number" -gt 0 ] && [ "$number" -le 65535 ] || {
    printf 'Ports must be between 1 and 65535.\n' >&2; exit 1
  }
done
directory="${DEPLOY_DIRECTORY:-$(read_env DEPLOY_DIRECTORY .env)}"; directory="${directory:-/opt/xray-proxy}"
repository="${DEPLOY_GIT_REPOSITORY:-$(read_env DEPLOY_GIT_REPOSITORY .env)}"
repository="${repository:-https://github.com/amirho1/xray-proxy.git}"
ref="${DEPLOY_GIT_REF:-$(read_env DEPLOY_GIT_REF .env)}"
[[ "$repository" =~ ^https://github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || { printf 'Use an HTTPS GitHub repository URL without credentials.\n' >&2; exit 1; }
[ -z "$ref" ] || [[ "$ref" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_./-]*$ ]] || { printf 'Set DEPLOY_GIT_REF to a branch or tag.\n' >&2; exit 1; }
[[ "$directory" =~ ^/[a-zA-Z0-9_/-]+$ ]] || { printf 'Invalid application directory.\n' >&2; exit 1; }

mkdir -p .deployment
chmod 700 .deployment
credentials="$root/.deployment/client.env"
proxy_password="$(read_env PROXY_PASSWORD "$credentials")"
if [ "${1:-}" = --rotate-password ] || [ -z "$proxy_password" ]; then
  proxy_password="$(openssl rand -hex 32)"
fi
username="$(read_env PROXY_USERNAME .env)"; username="${username:-xray}"
{
  write_env_value PROXY_URL "https://$ip:$port"
  write_env_value PROXY_USERNAME "$username"
  write_env_value PROXY_PASSWORD "$proxy_password"
} > "$credentials"
chmod 600 "$credentials"
work="$(mktemp -d "${TMPDIR:-/tmp}/xray-deploy.XXXXXX")"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
cat > "$work/askpass" <<'ASKPASS'
#!/bin/sh
printf '%s\n' "$XRAY_DEPLOY_SSH_PASSWORD"
ASKPASS
chmod 700 "$work/askpass"
export XRAY_DEPLOY_SSH_PASSWORD="$ssh_password" SSH_ASKPASS="$work/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}"
ssh_options=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=15
  -o ServerAliveCountMax=3 -o NumberOfPasswordPrompts=1 -p "$ssh_port")
printf 'Checking SSH access to %s:%s\n' "$target" "$ssh_port"
ssh "${ssh_options[@]}" "$target" true

bundle="$work/bundle"
mkdir -p "$bundle/scripts"
files=(docker-compose.yml docker-compose.https.yml docker-compose.test.yml
  scripts/init-config.sh scripts/render-config.mjs scripts/test-telegram-proxy.sh
  scripts/deploy.sh scripts/deploy-remote.sh scripts/prepare-runtime.sh scripts/deployment-common.sh)
for file in "${files[@]}"; do cp "$root/$file" "$bundle/$file"; done
{
  for key in XRAY_IMAGE_TAG HTTP_PROXY_PORT SOCKS_PROXY_PORT ENABLE_SOCKS SOCKS_ENABLE_UDP \
    SUBSCRIPTION_URL SUBSCRIPTION_USER_AGENT VLESS_URI OBSERVATORY_PROBE_URL \
    OBSERVATORY_PROBE_INTERVAL XRAY_LOG_LEVEL; do
    value="$(read_env "$key" .env)"
    if [ -n "$value" ]; then write_env_value "$key" "$value"; fi
  done
  write_env_value PROXY_USERNAME "$username"
  write_env_value PROXY_PASSWORD "$proxy_password"
  write_env_value ALLOW_UNAUTHENTICATED_PROXY false
  write_env_value COMPOSE_PROJECT_NAME xray-proxy
  write_env_value XRAY_NETWORK_NAME xray-proxy-net
  write_env_value XRAY_NETWORK_ALIAS xray-proxy
  write_env_value XRAY_CONFIG_GID 65532
  write_env_value XRAY_ACCESS_LOG none
  write_env_value XRAY_CONFIG_PATH config/config.json
  write_env_value HTTPS_PROXY_PORT "$port"
  write_env_value HTTPS_BIND_IP 0.0.0.0
} > "$bundle/.env"
printf -v install_command '%q ' bash scripts/deploy-remote.sh "$ip" "$port" "$directory" "$repository" "$ref"
bootstrap='set -eu; umask 077; staging=$(mktemp -d /tmp/xray-deploy.XXXXXX); trap '\''rm -rf "$staging"'\'' EXIT; tar -xzf - -C "$staging"; cd "$staging"; '
printf -v remote_command 'bash -c %q' "$bootstrap$install_command"
printf 'Deploying GitHub source plus the current local deployment files.\n'
COPYFILE_DISABLE=1 tar -czf - -C "$bundle" . | ssh "${ssh_options[@]}" "$target" "$remote_command"
printf -v certificate_command 'cat %q' "$directory/tls/server.crt"
ssh "${ssh_options[@]}" "$target" "$certificate_command" > "$root/.deployment/server.crt"
unset XRAY_DEPLOY_SSH_PASSWORD
verify_https_proxy "https://$ip:$port" "$root/.deployment/server.crt" "$credentials" 3
printf 'Credentials: %s (mode 0600)\nTrust certificate: %s\n' "$credentials" "$root/.deployment/server.crt"
