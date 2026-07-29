# Standalone Xray VLESS Proxy

This project runs a reusable HTTP/SOCKS proxy service backed by one VLESS outbound. Any request accepted by the local proxy inbounds is sent through the configured VLESS connection. There are no destination-based routing rules and no direct outbound fallback.

The service uses the official Xray-core Docker image, `ghcr.io/xtls/xray-core`, and keeps the proxy private to the Docker network by default.

The `xray` service does not set a fixed Docker `container_name`. Docker Compose assigns a project-scoped container name so Dokploy can recreate deployments without colliding with older containers. Other containers should use the stable network alias `xray-proxy`, not the Docker container name.

## Files

- `docker-compose.yml`: production Compose stack with internal-only proxy exposure.
- `docker-compose.host.example.yml`: optional override for publishing proxy ports on the Docker host.
- `docker-compose.dokploy.yml`: optional Dokploy/Traefik TCP TLS override for public HTTPS forward-proxy access.
- `docker-compose.test.yml`: optional curl-based Telegram proxy test service.
- `.env.example`: configurable values and placeholders.
- `scripts/init-config.sh`: Compose init script that creates `config/config.json` automatically.
- `scripts/render-config.mjs`: converts `VLESS_URI` and proxy settings into `config/config.json`.
- `scripts/test-telegram-proxy.sh`: runs an HTTPS request test through the Docker proxy.
- `config/config.example.json`: readable example of the generated Xray config shape.
- `config/config.json`: generated runtime config, ignored by Git because it contains secrets.

Expected directory structure:

```text
xray-proxy/
├── docker-compose.yml
├── docker-compose.host.example.yml
├── docker-compose.dokploy.yml
├── docker-compose.test.yml
├── .env
├── scripts/
│   ├── render-config.mjs
│   ├── init-config.sh
│   └── test-telegram-proxy.sh
└── config/
    ├── config.example.json
    └── config.json
```

`config/config.json` must be a regular file. It must not be a directory.

The Xray service mounts the whole configuration directory:

```yaml
volumes:
  - type: bind
    source: ./config
    target: /usr/local/etc/xray
    read_only: true
    bind:
      create_host_path: false
```

Inside the container, Xray reads `/usr/local/etc/xray/config.json`.

## Quick Start

Copy the example environment file:

```sh
cp .env.example .env
```

Edit `.env` and set:

- `VLESS_URI` to your full `vless://...` share link.
- `PROXY_USERNAME` and `PROXY_PASSWORD` to strong values.
- `ENABLE_SOCKS=true` or `false`, depending on whether you want SOCKS5.

Start the service:

```sh
docker compose up -d
```

On startup, Compose runs the one-shot `xray-init` service first. It executes `scripts/init-config.sh`, renders `config/config.json` from `.env`, and starts Xray only after the config exists.

By default, other containers on `xray-proxy-net` can reach:

- HTTP proxy: `http://xray-proxy:8080`
- SOCKS5 proxy: `socks5h://xray-proxy:1080`

No proxy port is published to the host unless you use the host override file.

## VLESS URI Conversion

Paste the full URI into `.env`:

```env
VLESS_URI='vless://UUID@server.example.com:443?encryption=none&security=reality&type=tcp&sni=www.example.com&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&spx=%2F&flow=xtls-rprx-vision#name'
```

Quote the value so the fragment after `#` is preserved.

The renderer maps URI fields into Xray JSON like this:

| VLESS URI field | Xray config field |
| --- | --- |
| URI userinfo before `@` | `outbounds[0].settings.id` |
| URI host | `outbounds[0].settings.address` |
| URI port | `outbounds[0].settings.port` |
| `encryption` | `outbounds[0].settings.encryption` |
| `flow` | `outbounds[0].settings.flow` |
| `security=reality` | `outbounds[0].streamSettings.security` |
| `sni` or `serverName` | `realitySettings.serverName` or `tlsSettings.serverName` |
| `fp` or `fingerprint` | `realitySettings.fingerprint` or `tlsSettings.fingerprint` |
| `pbk` | `realitySettings.password` |
| `sid` | `realitySettings.shortId` |
| `spx` | `realitySettings.spiderX` |
| `type`, `path`, `host`, `serviceName`, `mode`, `authority` | Relevant transport settings |

For REALITY, Xray currently documents the client public-key field as `password`. Many older configs and clients still call this `publicKey`; the renderer accepts `pbk`, `password`, or `publicKey` and writes `password`.

## Supported VLESS Settings

Required base fields:

- UUID/user ID: the value before `@`.
- Server address: the hostname or IP after `@`.
- Server port: the explicit port after the address.
- Encryption: usually `encryption=none`.

Supported transport security:

- `security=reality`
- `security=tls`
- `security=none`

Supported transports:

- `type=tcp` or `type=raw`: generates Xray `method: "raw"`.
- `type=xhttp` or `type=splithttp`: supports `path`, `host`, and `mode`.
- `type=grpc`: supports `serviceName`, `authority`, and `multiMode`.
- `type=ws` or `type=websocket`: supports `path` and `host`.
- `type=httpupgrade`: supports `path` and `host`.

REALITY is accepted only with RAW/TCP, XHTTP/SplitHTTP, or gRPC. The renderer fails on unsupported combinations, such as `security=reality&type=ws`, before Xray starts.

Common REALITY fields:

- `sni` or `serverName`: must match one of the server-side REALITY names.
- `fp`: browser fingerprint such as `chrome`, if supported by your Xray version.
- `pbk`: server REALITY public key.
- `sid`: short ID; may be empty only when the server allows an empty short ID.
- `spx`: spider path, usually `/` encoded as `%2F`.
- `flow`: often `xtls-rprx-vision` for TCP+REALITY servers that support Vision.

Do not mix fields from different VLESS links. UUID, server, port, SNI, public key, short ID, fingerprint, flow, and transport must match the same server profile.

## Service Commands

Start or restart, rendering `config/config.json` automatically before Xray starts:

```sh
docker compose up -d
```

Render or re-render manually after editing `.env`:

```sh
docker compose run --rm xray-init
```

Validate generated config:

```sh
docker compose run --rm --no-deps xray run -test -config /usr/local/etc/xray/config.json
```

Stop:

```sh
docker compose down
```

Restart after changing `.env`:

```sh
docker compose up -d --force-recreate
```

Update Xray:

```sh
docker compose pull xray
docker compose up -d
```

Inspect logs:

```sh
docker compose logs -f xray
```

## Optional Host Port Publishing

The default stack exposes proxy ports only inside Docker networking. To publish them on the host, use the override:

```sh
docker compose -f docker-compose.yml -f docker-compose.host.example.yml up -d
```

The override binds to `127.0.0.1` by default:

```env
HOST_BIND_IP=127.0.0.1
HOST_HTTP_PROXY_PORT=8080
HOST_SOCKS_PROXY_PORT=1080
```

Only change `HOST_BIND_IP` to `0.0.0.0` when you have a firewall, strong proxy credentials, and a clear reason to expose the proxy outside the host.

## Dokploy Public HTTPS Proxy

Use `docker-compose.dokploy.yml` when this stack is deployed by Dokploy and you want public users to reach the HTTP forward proxy securely at:

```text
https://USER:PASS@proxy.insta-shop.ir:443
```

This override does not make Xray speak TLS. Xray keeps listening as a plain HTTP forward proxy on the internal Docker port `8080`. Dokploy's Traefik terminates the public Let's Encrypt TLS connection, then forwards the decrypted TCP stream to Xray. This preserves HTTP `CONNECT` requests, which normal Traefik HTTP routers do not handle correctly for forward-proxy use.

For Dokploy deployments, the generated `config.json` is shared between `xray-init` and `xray` through the Compose-managed `xray-config` Docker volume. This keeps Xray from depending on a mutable cloned repo path after deployment. Local non-Dokploy Compose still writes `config/config.json` in the project directory.

Configure these values in `.env` or in Dokploy environment variables:

```env
PUBLIC_PROXY_DOMAIN=proxy.insta-shop.ir
TRAEFIK_ENTRYPOINT=websecure
TRAEFIK_CERT_RESOLVER=letsencrypt
DOKPLOY_NETWORK_NAME=dokploy-network
```

In Dokploy, remove any Domains-tab HTTP route for `proxy.insta-shop.ir`. A forward proxy must use the TCP labels in `docker-compose.dokploy.yml`, not a normal HTTPS web-app route.

In Dokploy Advanced settings, set the custom command to:

```sh
compose -f docker-compose.yml -f docker-compose.dokploy.yml up -d --remove-orphans
```

Dokploy prefixes custom commands with `docker`, so the command above runs as `docker compose ...`.

If an older deployment used the fixed container name `xray-proxy`, remove that old container once before redeploying:

```sh
docker rm -f xray-proxy
```

This removes only the stale Docker container object. The replacement service will still be reachable on Docker networks through the `xray-proxy` alias.

Keep public access authenticated:

```env
ALLOW_UNAUTHENTICATED_PROXY=false
PROXY_USERNAME=<strong-user>
PROXY_PASSWORD=<strong-password>
```

After deployment, confirm Traefik serves the Let's Encrypt certificate:

```sh
openssl s_client -connect proxy.insta-shop.ir:443 -servername proxy.insta-shop.ir -alpn http/1.1 -brief
```

Then confirm public proxy traffic reaches Xray and exits through the VLESS server:

```sh
curl -v --proxy "https://USER:PASS@proxy.insta-shop.ir:443" https://api.ipify.org
```

The curl trace should show an HTTP `CONNECT` tunnel before the destination TLS handshake. The returned IP should be the remote VLESS egress IP or the upstream route configured by that server.

If `xray` is unhealthy in Dokploy, confirm the shared config volume contains the rendered config:

```sh
docker compose -f docker-compose.yml -f docker-compose.dokploy.yml exec xray \
  /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
```

## Test With curl

From another container on the same Docker network:

```sh
docker run --rm --network xray-proxy-net curlimages/curl:latest \
  -x http://USER:PASS@xray-proxy:8080 https://api.ipify.org
```

SOCKS5, with proxy-side DNS resolution:

```sh
docker run --rm --network xray-proxy-net curlimages/curl:latest \
  -x socks5h://USER:PASS@xray-proxy:1080 https://api.ipify.org
```

If you enabled host publishing, test from the host:

```sh
curl -x http://USER:PASS@127.0.0.1:8080 https://api.ipify.org
curl -x socks5h://USER:PASS@127.0.0.1:1080 https://api.ipify.org
```

The returned IP should be the remote VLESS server's egress IP or the upstream route configured by that server.

Compare against direct egress from the same Docker host:

```sh
curl -sS https://api.ipify.org
```

If the proxy is working through a remote VLESS server, the direct IP and proxied IP are usually different.

## Automated Telegram Proxy Test

Run the automated test from a temporary container attached to the same Docker network as the proxy:

```sh
docker compose -f docker-compose.yml -f docker-compose.test.yml run --rm telegram-proxy-test
```

Do not run `scripts/test-telegram-proxy.sh` directly on the host with the default `PROXY_URL=http://xray:8080`. The hostname `xray` is a Docker Compose service name and resolves only from containers attached to `xray-proxy-net`.

The test defaults to the internal HTTP proxy endpoint:

```env
PROXY_URL=http://xray:8080
```

To test SOCKS5 with proxy-side DNS resolution, use `socks5h://`:

```sh
PROXY_URL=socks5h://xray:1080 docker compose -f docker-compose.yml -f docker-compose.test.yml run --rm telegram-proxy-test
```

The test follows redirects, applies connection and total request timeouts, treats HTTP status codes from `200` to `399` as successful, and exits non-zero for proxy, DNS, TLS, timeout, or unsuccessful HTTP status failures. It also disables proxy bypass with `--noproxy ""` and confirms proxy usage from curl diagnostics, such as an HTTP `CONNECT telegram.org:443` tunnel or SOCKS5H remote-DNS evidence.

Before the Telegram request, the test uses `VLESS_URI` to check whether Docker's direct public egress IP already matches the VLESS server IP. If they match, the test exits early because the host VPN or V2box route is probably tunneling Docker traffic through the same server that Dockerized Xray is trying to dial. Disable the host VPN while testing, or add DIRECT/bypass rules for the VLESS server hostname and IP, then restart Docker Desktop.

To skip only that guard:

```sh
SELF_ROUTE_CHECK=false docker compose -f docker-compose.yml -f docker-compose.test.yml run --rm telegram-proxy-test
```

If authentication is enabled, the Compose test service reads `PROXY_USERNAME` and `PROXY_PASSWORD` from `.env`. You can also embed credentials directly in the proxy URL:

```sh
PROXY_URL=http://USER:PASS@xray:8080 docker compose -f docker-compose.yml -f docker-compose.test.yml run --rm telegram-proxy-test
```

Example successful output:

```text
Telegram proxy test
Target URL: https://telegram.org
Proxy URL: http://xray:8080
Connect timeout: 10s
Request timeout: 30s
Self-route check: checking Docker egress and VLESS server route
Self-route check: direct Docker egress is 203.0.113.10; resolving example.com
Self-route check: VLESS server example.com resolves to 198.51.100.20; no routing loop detected

HTTP status: 200
Total duration: 1.234567s
Effective URL: https://telegram.org/
Proxy path: confirmed via HTTP CONNECT tunnel
SUCCESS: Telegram request succeeded through the proxy.
```

Example failed output:

```text
Telegram proxy test
Target URL: https://telegram.org
Proxy URL: http://bad-proxy:8080
Connect timeout: 10s
Request timeout: 30s
Self-route check: skipped (VLESS server address not provided)

HTTP status: 000
Total duration: 0.012345s
Effective URL: https://telegram.org/
Proxy path: not confirmed
FAIL: Proxy DNS resolution failed. The test container could not resolve the proxy host from PROXY_URL.
```

## Connect n8n

For an n8n HTTP Request node, open the node's options and set Proxy to:

```text
http://USER:PASS@xray-proxy:8080
```

If n8n runs in Docker, attach it to the same network:

```yaml
services:
  n8n:
    networks:
      - xray-proxy
    environment:
      HTTP_PROXY: http://USER:PASS@xray-proxy:8080
      HTTPS_PROXY: http://USER:PASS@xray-proxy:8080

networks:
  xray-proxy:
    external: true
    name: xray-proxy-net
```

n8n's HTTP Request node Proxy option takes precedence over global `HTTP_PROXY`, `HTTPS_PROXY`, or `ALL_PROXY` environment variables.

## Use From JavaScript

HTTP proxy with `undici`:

```js
import { fetch, ProxyAgent } from "undici";

const dispatcher = new ProxyAgent("http://USER:PASS@xray-proxy:8080");
const response = await fetch("https://api.ipify.org?format=json", { dispatcher });
console.log(await response.json());
```

SOCKS5 proxy with `socks-proxy-agent`:

```js
import https from "node:https";
import { SocksProxyAgent } from "socks-proxy-agent";

const agent = new SocksProxyAgent("socks5h://USER:PASS@xray-proxy:1080");

https.get("https://api.ipify.org?format=json", { agent }, (response) => {
  response.pipe(process.stdout);
});
```

Install libraries in your app as needed:

```sh
npm install undici socks-proxy-agent
```

## Use From Another Docker Container

Attach the application container to the external network:

```yaml
services:
  app:
    image: your-app:latest
    networks:
      - xray-proxy
    environment:
      HTTP_PROXY: http://USER:PASS@xray-proxy:8080
      HTTPS_PROXY: http://USER:PASS@xray-proxy:8080

networks:
  xray-proxy:
    external: true
    name: xray-proxy-net
```

Use `xray-proxy` as the proxy hostname unless you changed `XRAY_NETWORK_ALIAS`.

## Security Notes

- Keep `ALLOW_UNAUTHENTICATED_PROXY=false` unless the proxy is isolated and disposable.
- Use strong `PROXY_USERNAME` and `PROXY_PASSWORD` values.
- Do not expose HTTP or SOCKS proxy ports publicly without firewall rules.
- For public access through Dokploy, expose only the HTTPS TCP router on `proxy.insta-shop.ir`; leave Xray's plain HTTP and SOCKS ports internal.
- HTTP and SOCKS inbounds do not encrypt traffic between the application and Xray; keep that hop inside Docker networking, localhost, or another trusted network.
- Prefer `socks5h://` over `socks5://` so DNS is resolved through the proxy path instead of by the client.
- Treat `.env`, `VLESS_URI`, `config/config.json`, REALITY keys, and proxy credentials as secrets.

## Troubleshooting

Validate the config first:

```sh
docker compose config
ls -la config config/config.json
file config/config.json
docker compose run --rm --no-deps xray run -test -config /usr/local/etc/xray/config.json
```

Check logs:

```sh
docker compose logs -f xray
```

Common problems:

- Missing `config/config.json`: run `docker compose run --rm xray-init`, or start the stack with `docker compose up -d`.
- `read /usr/local/etc/xray/config.json: is a directory`: the host path `config/config.json` is a directory. Stop the stack, remove the empty directory, render the config again, validate, then start:

```sh
docker compose down --remove-orphans
rmdir config/config.json
docker compose run --rm xray-init
file config/config.json
docker compose run --rm --no-deps xray run -test -config /usr/local/etc/xray/config.json
docker compose up -d
docker compose ps
```

- Incorrect file bind mount: avoid `./config/config.json:/usr/local/etc/xray/config.json` when the host file may not already exist. This project mounts `./config:/usr/local/etc/xray:ro` so Docker does not create `config.json` as a directory.
- `empty "password"` or invalid REALITY public key: check `pbk` in the URI.
- REALITY handshake failures: verify SNI/serverName, public key, short ID, fingerprint, flow, and transport against the server profile.
- Validation rejects plain VLESS to a public server: set `security=tls` or `security=reality`, unless your server is private/trusted or uses VLESS encryption.
- `curl` works from the host but not another container: confirm the other container is on `xray-proxy-net` and uses `xray-proxy` as hostname.
- Automated Telegram test reports `Could not resolve proxy: xray`: run it through Compose with `docker compose -f docker-compose.yml -f docker-compose.test.yml run --rm telegram-proxy-test`. The hostname `xray` does not resolve from the host shell.
- Automated Telegram test reports proxy DNS failure from inside Compose: confirm the proxy container is running with `docker compose ps`, and use a proxy URL such as `http://xray:8080` or `socks5h://xray:1080`.
- Automated Telegram test reports that Docker direct egress matches the VLESS server IP: disable V2box or add DIRECT/bypass rules for the VLESS server hostname and IP, restart Docker Desktop, then retry.
- Automated Telegram test reports proxy unreachable: confirm the Xray service is healthy, the selected internal port is enabled, and the test command includes both `docker-compose.yml` and `docker-compose.test.yml`.
- Automated Telegram test reports TLS failure: check the upstream VLESS TLS/REALITY settings, system clock, certificate trust, SNI/serverName, public key, short ID, fingerprint, flow, and transport.
- Automated Telegram test reports timeout: increase `CONNECT_TIMEOUT` or `MAX_TIME` only after confirming the proxy logs do not show authentication or upstream connection failures.
- Automated Telegram test cannot confirm proxy usage: keep `PROXY_URL` set, do not use `socks5://`, and confirm curl diagnostics show either `CONNECT telegram.org:443` for HTTP proxy or remote DNS SOCKS5 output for `socks5h://`.
- n8n bypasses proxy: set the HTTP Request node Proxy option directly, or confirm `HTTP_PROXY` and `HTTPS_PROXY` are present in the n8n container environment.
- DNS leaks or wrong destination resolution: use SOCKS as `socks5h://...` or HTTP proxy URLs for HTTPS requests.

On native Linux, the official image runs as UID `65532`. The renderer writes `config/config.json` with mode `0644` so that non-root Xray can read the bind-mounted file.

## References

- Xray Docker installation: https://xtls.github.io/en/document/install.html
- Xray configuration overview: https://xtls.github.io/en/config/
- Xray HTTP inbound: https://xtls.github.io/en/config/inbounds/http.html
- Xray SOCKS inbound: https://xtls.github.io/en/config/inbounds/socks.html
- Xray VLESS outbound: https://xtls.github.io/en/config/outbounds/vless.html
- Xray transport and REALITY settings: https://xtls.github.io/en/config/transport.html and https://xtls.github.io/en/config/transports/reality.html
- n8n HTTP Request proxy option: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.httprequest/
- Dokploy Docker Compose domains: https://docs.dokploy.com/docs/core/docker-compose/domains
- Traefik TCP routers: https://doc.traefik.io/traefik/reference/routing-configuration/tcp/routing/router/
- Traefik TCP TLS: https://doc.traefik.io/traefik/reference/routing-configuration/tcp/tls/
