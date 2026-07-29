# OpenRouter Through Xray Proxy TLS Diagnostics

This file separates local findings from server-side tests. Replace placeholders before running commands. Do not paste real API keys, proxy passwords, or full VLESS URIs into shared logs.

## Confirmed From Local Files

- Workflow: `/Users/amirho/Projects/v2ray-config-tester/Shahrah - Tested Free VPN Config Post.json`.
- Failing node: `Generate Persian Copy with AI1`.
- OpenRouter endpoint: `https://openrouter.ai/api/v1/chat/completions`.
- HTTP method: `POST`.
- Request body: `={{ $json.requestBody }}` from `Prepare AI Request1`.
- Timeout: `30000` ms.
- Retry: enabled, `maxTries: 2`, `waitBetweenTries: 1500`.
- Previous proxy setting: `https://proxy.insta-shop.ir`.
- Corrected proxy setting in the workflow: `={{ $env.XRAY_PROXY_URL }}`.
- Corrected OpenRouter auth header: `={{ "Bearer " + $env.OPENROUTER_API_KEY }}`.
- Local rendered Xray inbound is a plaintext HTTP forward proxy on port `8080`, with proxy users enabled.
- Local rendered Xray outbound is VLESS over REALITY.
- Local Xray access logging is disabled with `XRAY_ACCESS_LOG=none`.

The active workflow was backed up before editing:

```sh
/Users/amirho/Projects/v2ray-config-tester/Shahrah - Tested Free VPN Config Post.json.bak-20260728T090129
```

## Most Likely Cause

The workflow was using `https://proxy.insta-shop.ir` as the proxy URL even though the Xray inbound is a plaintext HTTP forward proxy. If n8n and Xray are on the same server, n8n should use the internal Docker endpoint, for example:

```sh
XRAY_PROXY_URL='http://<url-encoded-proxy-user>:<url-encoded-proxy-pass>@xray-proxy:8080'
```

Do not route internal proxy traffic through the public Traefik hostname unless you intentionally operate a real HTTPS forward proxy and have tested CONNECT through that layer.

## Corrected n8n HTTP Request Node

Use this shape for `Generate Persian Copy with AI1`:

```text
Method: POST
URL: ={{ $json.aiApiUrl }}
Header Authorization: ={{ "Bearer " + $env.OPENROUTER_API_KEY }}
Header HTTP-Referer: https://shahrah.xyz
Header X-Title: Shahrah Hourly Tested Free VPN Telegram Post
Body: JSON, ={{ $json.requestBody }}
Proxy: ={{ $env.XRAY_PROXY_URL }}
Timeout: 30000
Retry: enabled, 2 tries, 1500 ms wait
```

Required n8n environment variables:

```sh
OPENROUTER_API_KEY='<openrouter-api-key>'
TELEGRAM_BOT_TOKEN='<telegram-bot-token>'
XRAY_PROXY_URL='http://<url-encoded-proxy-user>:<url-encoded-proxy-pass>@xray-proxy:8080'
NO_PROXY='localhost,127.0.0.1,::1,n8n,xray-proxy'
```

Only set global `HTTP_PROXY`, `HTTPS_PROXY`, or `ALL_PROXY` if every n8n outbound request should use the proxy. The HTTP Request node's own Proxy option should be enough for this workflow.

## Recommended Compose Shape

If n8n is attached to `dokploy-network`, give Xray a stable alias on that same network and avoid public Traefik exposure for the forward proxy:

```yaml
services:
  xray:
    expose:
      - "${HTTP_PROXY_PORT:-8080}"
      - "${SOCKS_PROXY_PORT:-1080}"
    networks:
      dokploy-network:
        aliases:
          - xray-proxy
      xray-proxy:
        aliases:
          - xray-proxy
    labels:
      - traefik.enable=false

networks:
  xray-proxy:
    name: ${XRAY_NETWORK_NAME:-xray-proxy-net}
    driver: bridge
  dokploy-network:
    external: true
```

If Dokploy requires labels elsewhere, remove the `proxy.insta-shop.ir` routers from this proxy service. A forward proxy is not the same as a normal HTTP reverse-proxied web app.

## Correct Xray HTTP Inbound Shape

The existing rendered inbound shape is appropriate. Keep credentials if the proxy is reachable by any container you do not fully trust:

```json
{
  "tag": "http-in",
  "listen": "0.0.0.0",
  "port": 8080,
  "protocol": "http",
  "settings": {
    "allowTransparent": false,
    "userLevel": 0,
    "users": [
      {
        "user": "<PROXY_USER>",
        "pass": "<PROXY_PASS>"
      }
    ]
  }
}
```

Do not change VLESS, REALITY, fingerprint, SNI, ALPN, or DNS settings until the tests below show that the CONNECT tunnel reaches Xray and the failure moves upstream.

## Server Diagnostics

Set placeholder values locally in the shell you use for diagnostics:

```sh
N8N_CONTAINER='<n8n-container-name>'
TRAEFIK_CONTAINER='<traefik-container-name>'
INTERNAL_PROXY='http://<url-encoded-proxy-user>:<url-encoded-proxy-pass>@xray-proxy:8080'
PUBLIC_HTTPS_PROXY='https://<url-encoded-proxy-user>:<url-encoded-proxy-pass>@proxy.insta-shop.ir'
```

Inspect containers and networks:

```sh
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Networks}}\t{{.Status}}'
docker inspect "$N8N_CONTAINER" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}'
docker inspect xray-proxy --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}'
docker network inspect xray-proxy-net
docker network inspect dokploy-network
```

Direct OpenRouter from the server, no proxy:

```sh
curl -v --noproxy '*' --connect-timeout 10 --max-time 30 https://openrouter.ai/api/v1/models -o /dev/null
openssl s_client -connect openrouter.ai:443 -servername openrouter.ai -alpn h2,http/1.1 -brief </dev/null
```

OpenRouter through the internal Xray HTTP proxy:

```sh
docker run --rm --network xray-proxy-net curlimages/curl:latest \
  -v --connect-timeout 10 --max-time 30 \
  --proxy "$INTERNAL_PROXY" \
  https://openrouter.ai/api/v1/models \
  -o /dev/null
```

If n8n and Xray share only `dokploy-network`, run the same test there:

```sh
docker run --rm --network dokploy-network curlimages/curl:latest \
  -v --connect-timeout 10 --max-time 30 \
  --proxy "$INTERNAL_PROXY" \
  https://openrouter.ai/api/v1/models \
  -o /dev/null
```

Confirm the HTTP CONNECT tunnel explicitly. The successful curl trace should show `CONNECT openrouter.ai:443` and a `200` proxy response before the OpenRouter TLS handshake:

```sh
docker run --rm --network xray-proxy-net --entrypoint sh curlimages/curl:latest -lc \
  'curl -v --proxytunnel --connect-timeout 10 --max-time 30 --proxy "$0" https://openrouter.ai/api/v1/models -o /dev/null 2>&1 | sed -E "s/(Proxy-Authorization: Basic )[A-Za-z0-9+/=]+/\\1<redacted>/I"' \
  "$INTERNAL_PROXY"
```

Test TLS and SNI through the HTTP proxy with OpenSSL, if your OpenSSL build supports `-proxy_user` and `-proxy_pass`:

```sh
docker run --rm --network xray-proxy-net alpine/openssl s_client \
  -proxy xray-proxy:8080 \
  -proxy_user '<PROXY_USER>' \
  -proxy_pass '<PROXY_PASS>' \
  -connect openrouter.ai:443 \
  -servername openrouter.ai \
  -alpn h2,http/1.1 \
  -brief </dev/null
```

Test the public Traefik path. This is expected to fail or behave differently if Traefik is being used as a reverse proxy in front of a forward proxy:

```sh
curl -v --connect-timeout 10 --max-time 30 \
  --proxy "$PUBLIC_HTTPS_PROXY" \
  https://openrouter.ai/api/v1/models \
  -o /dev/null

openssl s_client -connect proxy.insta-shop.ir:443 -servername proxy.insta-shop.ir -alpn http/1.1 -brief </dev/null
```

Check whether plain HTTP to the public host is just a Traefik redirect instead of a usable forward proxy:

```sh
curl -v --connect-timeout 10 --max-time 30 \
  --proxy 'http://<url-encoded-proxy-user>:<url-encoded-proxy-pass>@proxy.insta-shop.ir' \
  https://openrouter.ai/api/v1/models \
  -o /dev/null
```

Check DNS from the host, the Xray network namespace, and a same-network temporary container:

```sh
getent hosts openrouter.ai || nslookup openrouter.ai
docker run --rm --network container:xray-proxy busybox:1.36 nslookup openrouter.ai
docker run --rm --network xray-proxy-net busybox:1.36 nslookup xray-proxy
docker run --rm --network dokploy-network busybox:1.36 nslookup xray-proxy
```

Inspect n8n environment without printing secrets:

```sh
docker exec "$N8N_CONTAINER" sh -lc \
  'env | grep -Ei "^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|XRAY_PROXY_URL|OPENROUTER_API_KEY|TELEGRAM_BOT_TOKEN)=" | sed -E "s#(https?://)[^:@/]+:[^@/]+@#\\1<user>:<pass>@#; s#(OPENROUTER_API_KEY|TELEGRAM_BOT_TOKEN)=.*#\\1=<redacted>#"'
```

Test from inside the n8n container. If `curl` is not installed in the n8n image, use the next command instead:

```sh
docker exec "$N8N_CONTAINER" sh -lc \
  'curl -v --connect-timeout 10 --max-time 30 --proxy "$XRAY_PROXY_URL" https://openrouter.ai/api/v1/models -o /dev/null'

docker run --rm --network "container:$N8N_CONTAINER" curlimages/curl:latest \
  -v --connect-timeout 10 --max-time 30 \
  --proxy "$INTERNAL_PROXY" \
  https://openrouter.ai/api/v1/models \
  -o /dev/null
```

Inspect Xray config and logs:

```sh
docker exec xray-proxy /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
docker logs --tail=200 xray-proxy
docker logs --tail=200 "$TRAEFIK_CONTAINER" | grep -i 'proxy.insta-shop.ir\|handshake\|connect' || true
```

For one diagnostic redeploy only, enable Xray logs in Dokploy or Compose environment:

```sh
XRAY_LOG_LEVEL=debug
XRAY_ACCESS_LOG=/dev/stdout
XRAY_ERROR_LOG=/dev/stderr
```

Then redeploy/recreate Xray and watch:

```sh
docker logs -f --tail=200 xray-proxy
```

## How To Interpret Results

- Direct OpenRouter fails: the server cannot negotiate TLS to OpenRouter even without Xray.
- Internal proxy cannot resolve `xray-proxy`: n8n and Xray are not on the same Docker network or the alias is missing.
- Internal proxy returns `407`: proxy auth is missing or wrong; fix `XRAY_PROXY_URL`.
- Internal proxy shows no `CONNECT openrouter.ai:443`: n8n is not using the Xray HTTP proxy.
- Internal proxy shows `CONNECT` and then Xray logs a REALITY/VLESS error: investigate VLESS URI, SNI, fingerprint, short ID, flow, server reachability, and self-routing.
- Internal proxy shows `CONNECT` and then OpenRouter TLS fails: investigate OpenRouter TLS/SNI/ALPN or middlebox interference.
- Public `https://proxy.insta-shop.ir` fails before `CONNECT`: the failure is at n8n-to-Traefik/proxy TLS, not OpenRouter.
- Public HTTP proxy returns a redirect or 404: Traefik is acting as a web reverse proxy, not as a usable forward proxy endpoint.
- Xray logs show no access at all during n8n execution: n8n is using the wrong proxy URL, DNS cannot resolve the proxy, or global proxy variables are overriding the node.

## Minimal OpenRouter Request Through Internal Proxy

This request avoids verbose logging so the API key is not printed:

```sh
OPENROUTER_API_KEY='<openrouter-api-key>'
INTERNAL_PROXY='http://<url-encoded-proxy-user>:<url-encoded-proxy-pass>@xray-proxy:8080'

docker run --rm --network xray-proxy-net curlimages/curl:latest \
  -sS --fail-with-body --connect-timeout 10 --max-time 45 \
  --proxy "$INTERNAL_PROXY" \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
  -H 'HTTP-Referer: https://shahrah.xyz' \
  -H 'X-Title: Shahrah Hourly Tested Free VPN Telegram Post' \
  -H 'Content-Type: application/json' \
  --data '{"model":"deepseek/deepseek-v4-flash","messages":[{"role":"user","content":"Say OK only."}],"max_tokens":8}' \
  https://openrouter.ai/api/v1/chat/completions
```

## Final Verification Checklist

- `OPENROUTER_API_KEY` exists in the n8n container environment.
- `TELEGRAM_BOT_TOKEN` exists in the n8n container environment.
- `XRAY_PROXY_URL` uses `http://`, not `https://`.
- `XRAY_PROXY_URL` includes URL-encoded proxy credentials when Xray auth is enabled.
- n8n and Xray share a Docker network where `xray-proxy` resolves.
- The OpenRouter HTTP Request node's Proxy field is `={{ $env.XRAY_PROXY_URL }}`.
- The curl trace from the same network shows `CONNECT openrouter.ai:443` and a successful TLS handshake.
- Xray access/error logs show the request during the test.
- The public `proxy.insta-shop.ir` path is not used for internal n8n-to-Xray traffic.
- Temporary debug logging is returned to normal after diagnosis.
