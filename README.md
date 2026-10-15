# Standalone Xray Subscription Proxy (Auto-Fastest Node)

This project runs an HTTP/SOCKS proxy service backed by **Xray-core** with native **Observatory latency monitoring** and **leastPing dynamic balancing**.

It imports proxy configurations from `SUBSCRIPTION_URL` (or fallback `VLESS_URI`), monitors their latency in the background, and routes new requests to a low-latency server based on the latest probe results. Failover timing depends on the probe interval; existing connections are not migrated between servers.

The service uses the official Xray-core Docker image, `ghcr.io/xtls/xray-core`, and keeps proxy endpoints private to Docker networks by default.

---

## Key Features

- **Subscription Auto-Import**: Fetches and decodes Base64 or plain-text subscription feeds (`SUBSCRIPTION_URL`), with limits of 2 MiB, 512 lines, and 128 imported outbounds.
- **Multi-Protocol Support**: Parses `vless://` (REALITY/TLS), `ss://` (Shadowsocks 2022 & AEAD), `vmess://`, and `trojan://`.
- **Input Validation**: Skips invalid and unsupported subscription entries, including VMess informational entries that use port `1`.
- **Native Latency Benchmarking (`observatory`)**: Xray core pings all imported nodes in the background concurrently (default every 30s).
- **Fastest-Node Balancing (`leastPing`)**: All inbound HTTP and SOCKS traffic is routed to the server with the lowest ping.
- **Probe-Based Failover**: Routes new requests using the latest latency observations; the default probe interval is 30 seconds.
- **Single-Node Fallback**: Still supports single manual configs via `VLESS_URI` if no subscription URL is specified.

---

## Files

- `docker-compose.yml`: Production Compose stack with internal-only proxy exposure.
- `docker-compose.host.example.yml`: Optional override for publishing proxy ports on the host.
- `docker-compose.dokploy.yml`: Optional Dokploy/Traefik TCP TLS override for public HTTPS forward-proxy access.
- `docker-compose.test.yml`: Optional curl-based proxy test service.
- `.env.example`: Configuration templates and default settings.
- `scripts/init-config.sh`: Compose init script that executes `scripts/render-config.mjs`.
- `scripts/render-config.mjs`: Fetches subscription, parses configs, and generates `config/config.json`.
- `scripts/test-telegram-proxy.sh`: Diagnostic test script.
- `config/config.example.json`: Example of generated multi-outbound balanced Xray config.
- `config/config.json`: Generated runtime config (ignored by Git).

---

## Quick Start

1. **Copy the example environment file:**

   ```sh
   cp .env.example .env
   ```

2. **Configure `.env`:**

   ```env
   # Your subscription link
   SUBSCRIPTION_URL='https://example.com/sub/token#NAME'

   # Proxy authentication
   PROXY_USERNAME=myuser
   PROXY_PASSWORD=mypassword-super-strong
   ALLOW_UNAUTHENTICATED_PROXY=false

   # Group ID allowed to read the generated Xray config (default image GID)
   XRAY_CONFIG_GID=65532

   # Proxy ports (internal to Docker network)
   HTTP_PROXY_PORT=8080
   SOCKS_PROXY_PORT=1080
   ENABLE_SOCKS=true
   ```

3. **Start the stack:**

   ```sh
   docker compose up -d
   ```

On startup:
- `xray-init` runs first, fetches your subscription link, imports up to 128 nodes into `config/config.json`, and exits.
- `xray` starts, runs background latency checks on all imported servers, and serves incoming HTTP/SOCKS requests via the fastest server.

4. **Verify proxy status:**

   ```sh
   docker compose ps
   docker compose logs xray
   ```

---

## How Fastest Node Selection Works

Xray handles latency testing and routing natively inside its Go core:

```json
{
  "observatory": {
    "subjectSelector": ["proxy-"],
    "probeUrl": "https://cp.cloudflare.com/generate_204",
    "probeInterval": "30s",
    "enableConcurrency": true
  },
  "routing": {
    "domainStrategy": "AsIs",
    "balancers": [
      {
        "tag": "balancer-fastest",
        "selector": ["proxy-"],
        "strategy": {
          "type": "leastPing"
        }
      }
    ],
    "rules": [
      {
        "type": "field",
        "inboundTag": ["http-in", "socks-in"],
        "balancerTag": "balancer-fastest"
      }
    ]
  }
}
```

1. **Active Probing**: Every 30 seconds (configurable via `OBSERVATORY_PROBE_INTERVAL`), Xray sends a lightweight request to `OBSERVATORY_PROBE_URL` through every proxy outbound simultaneously.
2. **Dynamic Ranking**: Outbounds are ranked by latency (RTT). Failed/timed-out nodes are excluded.
3. **Route Traffic**: Incoming HTTP (`8080`) and SOCKS5 (`1080`) requests are automatically directed to the top-ranked outbound.

---

## Refreshing Subscription Configs

To update the server list from your subscription provider:

```sh
docker compose up -d --force-recreate xray-init xray
```

---

## Configuration Reference

| Variable | Default | Description |
| --- | --- | --- |
| `SUBSCRIPTION_URL` | *(empty)* | Subscription link returning Base64 or plain proxy URIs |
| `SUBSCRIPTION_USER_AGENT` | `v2rayN/6.23` | User-Agent used when downloading the subscription |
| `OBSERVATORY_PROBE_URL` | `https://cp.cloudflare.com/generate_204` | Lightweight endpoint for latency checks |
| `OBSERVATORY_PROBE_INTERVAL` | `30s` | Frequency of background latency checks (e.g. `15s`, `30s`, `1m`) |
| `VLESS_URI` | *(empty)* | Optional fallback single VLESS link (used if `SUBSCRIPTION_URL` is empty) |
| `HTTP_PROXY_PORT` | `8080` | Local HTTP proxy listening port |
| `SOCKS_PROXY_PORT` | `1080` | Local SOCKS5 proxy listening port |
| `ENABLE_SOCKS` | `true` | Whether to expose SOCKS5 inbound |
| `SOCKS_ENABLE_UDP` | `false` | Enable UDP support on SOCKS inbound |
| `PROXY_USERNAME` | *(none)* | Username for HTTP/SOCKS authentication |
| `PROXY_PASSWORD` | *(none)* | Password for HTTP/SOCKS authentication |
| `ALLOW_UNAUTHENTICATED_PROXY` | `false` | Set to `true` to disable proxy authentication |
| `XRAY_LOG_LEVEL` | `warning` | Xray log level (`debug`, `info`, `warning`, `error`, `none`) |
| `XRAY_ACCESS_LOG` | `none` | Xray access log destination (`none` or path) |
| `XRAY_CONFIG_GID` | `65532` | Group that can read the generated config file (mode `0640`) |

The generated config contains proxy credentials and upstream node credentials. Compose assigns it mode `0640` and the configured group so Xray can read it; limit membership in that group on shared hosts.

---

## Testing the Proxy

From another container on the same Docker network (`xray-proxy-net`):

```sh
# HTTP Proxy Test
curl -x http://username:password@xray-proxy:8080 https://api.ipify.org?format=json

# SOCKS5 Test
curl -x socks5h://username:password@xray-proxy:1080 https://api.ipify.org?format=json
```

If you published ports to the host via `docker-compose.host.example.yml`:

```sh
curl -x http://username:password@127.0.0.1:8080 https://api.ipify.org?format=json
```

---

## Deploying on Dokploy (Internal Proxy for All Services)

Dokploy runs all its applications and services on a shared Docker bridge network called `dokploy-network`.

When deployed on Dokploy with `docker-compose.dokploy.yml`, `xray-proxy` automatically joins `dokploy-network` under the network alias `xray-proxy`.

### How to Deploy in Dokploy UI:
1. In Dokploy, create a new **Compose** application (pointing to your Git repo or pasting the files).
2. Set **Compose Path** to:
   ```text
   docker-compose.yml,docker-compose.dokploy.yml
   ```
3. Set your **Environment Variables** in the Dokploy dashboard:
   ```env
   SUBSCRIPTION_URL=https://your-subscription-url
   PROXY_USERNAME=myuser
   PROXY_PASSWORD=mypassword
   DOKPLOY_NETWORK_NAME=dokploy-network
   ```
4. Click **Deploy**.

### How Other Dokploy Services Connect:
Any other container or service running in your Dokploy instance can immediately use the proxy through the internal Docker network:

- **HTTP Proxy**: `http://myuser:mypassword@xray-proxy:8080`
- **SOCKS5 Proxy**: `socks5h://myuser:mypassword@xray-proxy:1080`

Example in another service's environment variables (e.g. Telegram bot, scraper, n8n, etc.):
```env
HTTP_PROXY=http://myuser:mypassword@xray-proxy:8080
HTTPS_PROXY=http://myuser:mypassword@xray-proxy:8080
ALL_PROXY=socks5h://myuser:mypassword@xray-proxy:1080
```
No ports need to be opened to the public internet. All traffic stays fast and encrypted inside Dokploy's internal network.
