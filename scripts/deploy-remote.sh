#!/usr/bin/env bash
# Invoked by deploy.sh after its bundle has been transferred over SSH.
set -euo pipefail
umask 077
bundle="$(cd "$(dirname "$0")/.." && pwd)"
source "$bundle/scripts/deployment-common.sh"

ip="$1" port="$2" directory="$3" repository="$4" ref="$5"
[ "$(id -u)" = 0 ] || { printf 'Remote deployment requires root.\n' >&2; exit 1; }
distribution="$(read_env ID /etc/os-release)"
case "$distribution" in ubuntu|debian) ;; *) printf 'Supported servers: Ubuntu or Debian.\n' >&2; exit 1 ;; esac
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -qq
apt-get install -y -qq git curl openssl ca-certificates jq
if ! command -v docker > /dev/null || ! docker compose version > /dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$distribution/gpg" -o /etc/apt/keyrings/docker.asc
  chmod 644 /etc/apt/keyrings/docker.asc
  codename="$(read_env UBUNTU_CODENAME /etc/os-release)"
  codename="${codename:-$(read_env VERSION_CODENAME /etc/os-release)}"
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$distribution
Suites: $codename
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

install -d -m 700 "$directory" "$directory/releases"
release="$directory/releases/$(date -u +%Y%m%dT%H%M%S)-$$"
printf 'Fetching GitHub source (%s) into %s\n' "${ref:-default branch}" "$release"
clone_options=(--depth 1 --single-branch)
if [ -n "$ref" ]; then clone_options+=(--branch "$ref"); fi
GIT_TERMINAL_PROMPT=0 git clone "${clone_options[@]}" "$repository" "$release"
# Overlay the current working files so uncommitted deployment changes are included.
for file in docker-compose.yml docker-compose.https.yml docker-compose.test.yml \
  scripts/init-config.sh scripts/render-config.mjs scripts/test-telegram-proxy.sh \
  scripts/deploy.sh scripts/deploy-remote.sh scripts/prepare-runtime.sh scripts/deployment-common.sh; do
  install -D -m 644 "$bundle/$file" "$release/$file"
done
install -m 600 "$bundle/.env" "$release/.env"
tls="$directory/tls"
install -d -m 750 -g 65532 "$tls"
if [ ! -f "$tls/server.key" ] || [ ! -f "$tls/server.crt" ] ||
  ! openssl x509 -in "$tls/server.crt" -checkip "$ip" -noout > /dev/null 2>&1 ||
  ! openssl x509 -in "$tls/server.crt" -checkend 2592000 -noout > /dev/null 2>&1; then
  openssl req -x509 -newkey rsa:3072 -sha256 -days 365 -nodes -subj "/CN=$ip" \
    -addext "subjectAltName=IP:$ip,IP:127.0.0.1" -addext extendedKeyUsage=serverAuth \
    -keyout "$tls/server.key" -out "$tls/server.crt" > /dev/null 2>&1
fi
chown root:65532 "$tls/server.key"
chmod 640 "$tls/server.key"
chmod 644 "$tls/server.crt"
write_env_value DEPLOY_TLS_DIR "$tls" >> "$release/.env"
mkdir -p "$release/config"
chown root:65532 "$release/config"
chmod 750 "$release/config"
cd "$release"
compose config --quiet
compose pull --quiet xray-init xray
compose run --rm --no-deps xray-init
bash scripts/prepare-runtime.sh
compose up -d --no-deps xray
healthy=false
for _ in $(seq 1 30); do
  container="$(compose ps -q xray)"
  if [ -n "$container" ] && [ "$(docker inspect --format '{{.State.Health.Status}}' "$container")" = healthy ]; then
    healthy=true
    break
  fi
  sleep 2
done
[ "$healthy" = true ] || { printf 'Xray did not become healthy.\n' >&2; exit 1; }
verify_https_proxy "https://127.0.0.1:$port" "$tls/server.crt" .env 6
ln -s "$release" "$directory/.current-$$"
mv -Tf "$directory/.current-$$" "$directory/current"
compose ps
printf 'Deployment ready: https://%s:%s\n' "$ip" "$port"
