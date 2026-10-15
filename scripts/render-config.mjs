#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const DEFAULT_CONFIG_PATH = "config/config.json";
const DEFAULT_USER_AGENT = "v2rayN/6.23";
const DEFAULT_PROBE_URL = "https://cp.cloudflare.com/generate_204";
const DEFAULT_PROBE_INTERVAL = "30s";
const MAX_SUBSCRIPTION_BYTES = 2 * 1024 * 1024;
const MAX_SUBSCRIPTION_LINES = 512;
const MAX_SUBSCRIPTION_OUTBOUNDS = 128;
const DEFAULT_XRAY_CONFIG_GID = 65532;

const BOOL_TRUE = new Set(["1", "true", "yes", "y", "on"]);
const BOOL_FALSE = new Set(["0", "false", "no", "n", "off"]);
const REALITY_METHODS = new Set(["raw", "xhttp", "splithttp", "grpc"]);
const SUPPORTED_SECURITY = new Set(["none", "tls", "reality"]);

await main();

async function main() {
  try {
    loadDotEnv(".env");

    const outputPath = env("XRAY_CONFIG_PATH", DEFAULT_CONFIG_PATH);
    const config = await buildConfig();
    prepareOutputPath(outputPath);
    fs.writeFileSync(outputPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o640 });
    fs.chmodSync(outputPath, 0o640);
    const outputStat = fs.statSync(outputPath);
    const gidValue = env("XRAY_CONFIG_GID", String(DEFAULT_XRAY_CONFIG_GID)).trim();
    const xrayConfigGid = Number(gidValue);
    if (
      !/^\d+$/.test(gidValue) ||
      !Number.isSafeInteger(xrayConfigGid) ||
      xrayConfigGid > 0xffffffff
    ) {
      throw new Error("XRAY_CONFIG_GID must be a non-negative integer.");
    }
    fs.chownSync(outputPath, outputStat.uid, xrayConfigGid);
    fs.chmodSync(outputPath, 0o640);
    console.log(`Rendered Xray config to ${outputPath} with ${config.outbounds.length} outbounds.`);
  } catch (error) {
    console.error(`Config render failed: ${error.message}`);
    process.exit(1);
  }
}

async function buildConfig() {
  const subscriptionUrl = env("SUBSCRIPTION_URL", "").trim();
  const vlessUri = env("VLESS_URI", "").trim();

  let outbounds = [];

  if (subscriptionUrl) {
    console.log("Fetching subscription.");
    try {
      outbounds = await importSubscription(subscriptionUrl);
      console.log(`Imported ${outbounds.length} valid outbounds from subscription.`);
    } catch (err) {
      console.warn(`Failed to import from SUBSCRIPTION_URL: ${err.message}`);
    }
  }

  // Fallback to VLESS_URI if subscription returned no outbounds
  if (outbounds.length === 0 && vlessUri) {
    console.log("Using fallback VLESS_URI from environment.");
    const parsed = parseVlessUri(vlessUri, "proxy-1");
    outbounds.push(buildVlessOutbound(parsed));
  }

  if (outbounds.length === 0) {
    throw new Error(
      "No valid proxy configurations found. Please provide a working SUBSCRIPTION_URL or VLESS_URI in .env.",
    );
  }

  const httpPort = parsePort(env("HTTP_PROXY_PORT", "8080"), "HTTP_PROXY_PORT");
  const socksPort = parsePort(env("SOCKS_PROXY_PORT", "1080"), "SOCKS_PROXY_PORT");
  const enableSocks = parseBool(env("ENABLE_SOCKS", "true"), "ENABLE_SOCKS");
  const socksUdp = parseBool(env("SOCKS_ENABLE_UDP", "false"), "SOCKS_ENABLE_UDP");
  const allowNoAuth = parseBool(
    env("ALLOW_UNAUTHENTICATED_PROXY", "false"),
    "ALLOW_UNAUTHENTICATED_PROXY",
  );
  const proxyUsers = buildProxyUsers(allowNoAuth);

  const inbounds = [buildHttpInbound(httpPort, proxyUsers)];
  if (enableSocks) {
    inbounds.push(buildSocksInbound(socksPort, proxyUsers, socksUdp));
  }

  const log = {
    loglevel: env("XRAY_LOG_LEVEL", "warning"),
    access: env("XRAY_ACCESS_LOG", "none"),
  };

  const errorLog = env("XRAY_ERROR_LOG", "");
  if (errorLog) {
    log.error = errorLog;
  }

  const probeUrl = env("OBSERVATORY_PROBE_URL", DEFAULT_PROBE_URL);
  const probeInterval = env("OBSERVATORY_PROBE_INTERVAL", DEFAULT_PROBE_INTERVAL);

  const observatory = {
    subjectSelector: ["proxy-"],
    probeUrl,
    probeInterval,
    enableConcurrency: true,
  };

  const inboundTags = ["http-in"];
  if (enableSocks) {
    inboundTags.push("socks-in");
  }

  const routing = {
    domainStrategy: "AsIs",
    balancers: [
      {
        tag: "balancer-fastest",
        selector: ["proxy-"],
        strategy: {
          type: "leastPing",
        },
      },
    ],
    rules: [
      {
        type: "field",
        inboundTag: inboundTags,
        balancerTag: "balancer-fastest",
      },
    ],
  };

  return {
    log,
    inbounds,
    observatory,
    routing,
    outbounds,
  };
}

async function importSubscription(subscriptionUrl) {
  const userAgent = env("SUBSCRIPTION_USER_AGENT", DEFAULT_USER_AGENT);
  const rawContent = await fetchSubscription(subscriptionUrl, userAgent);
  const decodedContent = decodeSubscriptionContent(rawContent);

  let lineCount = decodedContent.length > 0 ? 1 : 0;
  for (let i = 0; i < decodedContent.length; i++) {
    if (decodedContent[i] === "\n" && i < decodedContent.length - 1) {
      lineCount++;
    }
  }
  if (lineCount > MAX_SUBSCRIPTION_LINES) {
    throw new Error(`Subscription exceeds the ${MAX_SUBSCRIPTION_LINES} line limit.`);
  }

  const lines = decodedContent
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  const outbounds = [];
  let count = 0;

  for (const line of lines) {
    let outbound;
    try {
      count++;
      const tag = `proxy-${count}`;
      outbound = parseProxyUri(line, tag);
    } catch (err) {
      console.warn(`[Skip] Could not parse config #${count}: ${err.message}`);
      continue;
    }

    if (outbound) {
      if (outbounds.length >= MAX_SUBSCRIPTION_OUTBOUNDS) {
        throw new Error(
          `Subscription exceeds the ${MAX_SUBSCRIPTION_OUTBOUNDS} outbound limit.`,
        );
      }
      outbounds.push(outbound);
    }
  }

  return outbounds;
}

async function fetchSubscription(url, userAgent) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 15000);

  try {
    const res = await fetch(url, {
      headers: {
        "User-Agent": userAgent,
        Accept: "*/*",
      },
      signal: controller.signal,
      redirect: "follow",
    });

    if (!res.ok) {
      throw new Error(`HTTP ${res.status} ${res.statusText}`);
    }

    const contentLength = Number(res.headers.get("content-length"));
    if (Number.isFinite(contentLength) && contentLength > MAX_SUBSCRIPTION_BYTES) {
      await res.body?.cancel();
      throw new Error(`Subscription exceeds the ${MAX_SUBSCRIPTION_BYTES}-byte limit.`);
    }

    if (!res.body) {
      return "";
    }

    const reader = res.body.getReader();
    const chunks = [];
    let totalBytes = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }

        totalBytes += value.byteLength;
        if (totalBytes > MAX_SUBSCRIPTION_BYTES) {
          await reader.cancel();
          throw new Error(`Subscription exceeds the ${MAX_SUBSCRIPTION_BYTES}-byte limit.`);
        }
        chunks.push(Buffer.from(value));
      }
    } finally {
      reader.releaseLock();
    }

    return Buffer.concat(chunks, totalBytes).toString("utf8");
  } finally {
    clearTimeout(timeoutId);
  }
}

function decodeSubscriptionContent(raw) {
  const trimmed = raw.trim();
  // If it already looks like plaintext proxy links, return as-is
  if (
    trimmed.startsWith("vless://") ||
    trimmed.startsWith("vmess://") ||
    trimmed.startsWith("ss://") ||
    trimmed.startsWith("trojan://")
  ) {
    return trimmed;
  }

  // Try decoding base64 (standard for v2ray subscriptions)
  try {
    const cleaned = trimmed.replace(/\s+/g, "");
    const decoded = Buffer.from(cleaned, "base64").toString("utf8");
    if (
      decoded.includes("://") ||
      decoded.includes("vmess://") ||
      decoded.includes("vless://") ||
      decoded.includes("ss://")
    ) {
      return decoded;
    }
  } catch (err) {
    // Ignore and fallback
  }

  return trimmed;
}

function parseProxyUri(line, tag) {
  if (line.startsWith("vless://")) {
    const parsed = parseVlessUri(line, tag);
    return buildVlessOutbound(parsed);
  }

  if (line.startsWith("ss://")) {
    return parseShadowsocksUri(line, tag);
  }

  if (line.startsWith("vmess://")) {
    return parseVmessUri(line, tag);
  }

  if (line.startsWith("trojan://")) {
    return parseTrojanUri(line, tag);
  }

  const protocol = line.match(/^([a-z][a-z0-9+.-]*):\/\//i)?.[1] || "unknown";
  throw new Error(`Unsupported protocol: ${protocol}.`);
}

function buildProxyUsers(allowNoAuth) {
  const username = env("PROXY_USERNAME", "");
  const password = env("PROXY_PASSWORD", "");

  if (!username && !password && allowNoAuth) {
    return [];
  }

  if (!username || !password) {
    throw new Error(
      "Set both PROXY_USERNAME and PROXY_PASSWORD, or set ALLOW_UNAUTHENTICATED_PROXY=true.",
    );
  }

  return [{ user: username, pass: password }];
}

function buildHttpInbound(port, users) {
  const settings = {
    allowTransparent: false,
    userLevel: 0,
  };

  if (users.length > 0) {
    settings.users = users;
  }

  return {
    tag: "http-in",
    listen: "0.0.0.0",
    port,
    protocol: "http",
    settings,
  };
}

function buildSocksInbound(port, users, udp) {
  const settings = {
    auth: users.length > 0 ? "password" : "noauth",
    udp,
    userLevel: 0,
  };

  if (users.length > 0) {
    settings.users = users;
  }

  return {
    tag: "socks-in",
    listen: "0.0.0.0",
    port,
    protocol: "socks",
    settings,
  };
}

function buildVlessOutbound(parsed) {
  const settings = {
    address: parsed.address,
    port: parsed.port,
    id: parsed.id,
    encryption: parsed.encryption,
  };

  if (parsed.flow) {
    settings.flow = parsed.flow;
  }

  return {
    tag: parsed.tag,
    protocol: "vless",
    settings,
    streamSettings: buildStreamSettings(parsed),
  };
}

function buildStreamSettings(parsed) {
  const streamSettings = {
    method: parsed.method,
    security: parsed.security,
  };

  Object.assign(streamSettings, buildTransportSettings(parsed));

  if (parsed.security === "reality") {
    if (!REALITY_METHODS.has(parsed.method)) {
      throw new Error(
        `REALITY supports raw, xhttp/splithttp, and grpc transports in Xray; got type=${parsed.method}.`,
      );
    }

    const serverName = firstParam(parsed.params, ["sni", "serverName"]);
    const fingerprint = firstParam(parsed.params, ["fp", "fingerprint"]);
    const publicKey = firstParam(parsed.params, ["pbk", "password", "publicKey"]);

    requireValue(serverName, "REALITY requires sni or serverName in VLESS_URI.");
    requireValue(fingerprint, "REALITY requires fp or fingerprint in VLESS_URI.");
    requireValue(publicKey, "REALITY requires pbk in VLESS_URI.");

    const shortId = firstParam(parsed.params, ["sid", "shortId"]) ?? "";
    const spiderX = firstParam(parsed.params, ["spx", "spiderX"]) || "/";

    validateRealityPublicKey(publicKey);
    validateRealityShortId(shortId);
    validateRealitySpiderX(spiderX);

    streamSettings.realitySettings = {
      fingerprint,
      serverName,
      password: publicKey,
      shortId,
      spiderX,
    };
  }

  if (parsed.security === "tls") {
    const tlsSettings = {};
    const serverName = firstParam(parsed.params, ["sni", "serverName"]);
    const fingerprint = firstParam(parsed.params, ["fp", "fingerprint"]);
    const alpn = firstParam(parsed.params, ["alpn"]);

    if (serverName) {
      tlsSettings.serverName = serverName;
    }

    if (fingerprint) {
      tlsSettings.fingerprint = fingerprint;
    }

    if (alpn) {
      tlsSettings.alpn = alpn.split(",").map((item) => item.trim()).filter(Boolean);
    }

    streamSettings.tlsSettings = tlsSettings;
  }

  return streamSettings;
}

function buildTransportSettings(parsed) {
  const params = parsed.params;
  const pathValue = firstParam(params, ["path"]) || "/";
  const host = firstParam(params, ["host"]);

  switch (parsed.method) {
    case "raw": {
      const headerType = (firstParam(params, ["headerType"]) || "none").toLowerCase();
      if (headerType !== "none") {
        throw new Error(`Unsupported raw/tcp headerType=${headerType}; use headerType=none.`);
      }
      return {};
    }
    case "xhttp":
    case "splithttp": {
      const xhttpSettings = {};
      if (host) {
        xhttpSettings.host = host;
      }
      if (pathValue) {
        xhttpSettings.path = pathValue;
      }
      const mode = firstParam(params, ["mode"]);
      if (mode) {
        xhttpSettings.mode = mode;
      }
      return { xhttpSettings };
    }
    case "grpc": {
      const grpcSettings = {};
      const serviceName = firstParam(params, ["serviceName"]);
      const authority = firstParam(params, ["authority", "host"]);
      const multiMode = firstParam(params, ["multiMode"]);
      if (serviceName) {
        grpcSettings.serviceName = serviceName;
      }
      if (authority) {
        grpcSettings.authority = authority;
      }
      if (multiMode) {
        grpcSettings.multiMode = parseBool(multiMode, "multiMode");
      }
      return { grpcSettings };
    }
    case "websocket": {
      const wsSettings = { path: pathValue };
      if (host) {
        wsSettings.host = host;
      }
      return { wsSettings };
    }
    case "httpupgrade": {
      const httpupgradeSettings = { path: pathValue };
      if (host) {
        httpupgradeSettings.host = host;
      }
      return { httpupgradeSettings };
    }
    default:
      throw new Error(`Unsupported transport type=${parsed.method}.`);
  }
}

function parseVlessUri(uri, tag) {
  let parsedUrl;

  try {
    parsedUrl = new URL(uri.trim());
  } catch (error) {
    throw new Error(`VLESS URI is not a valid URI: ${error.message}`);
  }

  if (parsedUrl.protocol !== "vless:") {
    throw new Error("VLESS URI must start with vless://.");
  }

  const id = decodeURIComponent(parsedUrl.username);
  requireValue(id, "VLESS URI must include the UUID/user ID before @.");

  const address = stripIpv6Brackets(parsedUrl.hostname);
  requireValue(address, "VLESS URI must include a server address.");

  if (!parsedUrl.port) {
    throw new Error("VLESS URI must include an explicit server port.");
  }

  const port = parsePort(parsedUrl.port, "VLESS URI port");
  const params = parsedUrl.searchParams;
  const security = (firstParam(params, ["security"]) || "none").toLowerCase();
  if (!SUPPORTED_SECURITY.has(security)) {
    throw new Error(`Unsupported security=${security}; expected none, tls, or reality.`);
  }

  const method = normalizeTransport(firstParam(params, ["type", "method", "network"]) || "tcp");
  const encryption = firstParam(params, ["encryption"]) || "none";
  const flow = firstParam(params, ["flow"]) || "";

  return {
    tag,
    id,
    address,
    port,
    params,
    security,
    method,
    encryption,
    flow,
  };
}

function parseShadowsocksUri(uri, tag) {
  let address = "";
  let port = 0;
  let method = "";
  let password = "";

  const trimmed = uri.trim();
  const hashIdx = trimmed.indexOf("#");
  const mainPart = hashIdx !== -1 ? trimmed.slice(0, hashIdx) : trimmed;
  const withoutScheme = mainPart.replace(/^ss:\/\//, "");

  if (withoutScheme.includes("@")) {
    // SIP002 format: ss://[base64(method:password)]@hostname:port
    const atIdx = withoutScheme.indexOf("@");
    const encodedUser = withoutScheme.slice(0, atIdx);
    const hostPort = withoutScheme.slice(atIdx + 1);

    // Decode user info
    let decodedUser = decodeURIComponent(encodedUser);
    try {
      const b64Decoded = Buffer.from(decodedUser, "base64").toString("utf8");
      if (b64Decoded.includes(":")) {
        decodedUser = b64Decoded;
      }
    } catch (e) {}

    const colonIdx = decodedUser.indexOf(":");
    if (colonIdx === -1) {
      throw new Error("Shadowsocks URI missing cipher method or password.");
    }
    method = decodedUser.slice(0, colonIdx);
    password = decodedUser.slice(colonIdx + 1);

    const parsedHp = parseHostPort(hostPort);
    address = parsedHp.address;
    port = parsedHp.port;
  } else {
    // Legacy base64 format: ss://base64(method:password@hostname:port)
    let decoded = "";
    try {
      decoded = Buffer.from(decodeURIComponent(withoutScheme), "base64").toString("utf8");
    } catch (e) {
      throw new Error(`Shadowsocks legacy decode failed: ${e.message}`);
    }

    const atIdx = decoded.indexOf("@");
    if (atIdx === -1) {
      throw new Error("Invalid Shadowsocks base64 string (missing @).");
    }

    const userPart = decoded.slice(0, atIdx);
    const hostPort = decoded.slice(atIdx + 1);

    const colonIdx = userPart.indexOf(":");
    if (colonIdx === -1) {
      throw new Error("Shadowsocks URI missing cipher method or password.");
    }
    method = userPart.slice(0, colonIdx);
    password = userPart.slice(colonIdx + 1);

    const parsedHp = parseHostPort(hostPort);
    address = parsedHp.address;
    port = parsedHp.port;
  }

  requireValue(address, "Shadowsocks address is required.");
  requireValue(method, "Shadowsocks method is required.");
  requireValue(password, "Shadowsocks password is required.");

  return {
    tag,
    protocol: "shadowsocks",
    settings: {
      servers: [
        {
          address,
          port,
          method,
          password,
        },
      ],
    },
  };
}

function parseVmessUri(uri, tag) {
  const rawBase64 = uri.replace(/^vmess:\/\//, "").trim();
  let obj;
  try {
    const jsonStr = Buffer.from(rawBase64, "base64").toString("utf8");
    obj = JSON.parse(jsonStr);
  } catch (err) {
    throw new Error(`Invalid VMess JSON format: ${err.message}`);
  }

  const port = Number(obj.port);
  if (!port || port <= 1 || port > 65535) {
    throw new Error(`Informational / invalid port in VMess config: ${obj.port}`);
  }

  const address = String(obj.add || "").trim();
  if (!address || /[\s\u0600-\u06FF]/.test(address)) {
    throw new Error(`Invalid server address in VMess config: "${address}"`);
  }

  const id = String(obj.id || "").trim();
  requireValue(id, "VMess requires uuid / id.");

  const method = normalizeSubscriptionTransport(obj.net || "tcp");
  const security = obj.tls === "tls" ? "tls" : "none";

  const streamSettings = {
    method,
    security,
  };

  if (security === "tls") {
    streamSettings.tlsSettings = {
      serverName: obj.sni || obj.host || address,
    };
    if (obj.fp) {
      streamSettings.tlsSettings.fingerprint = obj.fp;
    }
    if (obj.alpn) {
      streamSettings.tlsSettings.alpn = String(obj.alpn)
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
    }
  }

  if (method === "websocket") {
    streamSettings.wsSettings = {
      path: obj.path || "/",
    };
    if (obj.host) {
      streamSettings.wsSettings.headers = { Host: obj.host };
    }
  } else if (method === "grpc") {
    streamSettings.grpcSettings = {
      serviceName: obj.path || "",
    };
  }

  return {
    tag,
    protocol: "vmess",
    settings: {
      vnext: [
        {
          address,
          port,
          users: [
            {
              id,
              alterId: Number(obj.aid) || 0,
              security: obj.scy || "auto",
            },
          ],
        },
      ],
    },
    streamSettings,
  };
}

function parseTrojanUri(uri, tag) {
  let parsedUrl;
  try {
    parsedUrl = new URL(uri.trim());
  } catch (error) {
    throw new Error(`Trojan URI is not valid: ${error.message}`);
  }

  const password = decodeURIComponent(parsedUrl.username || "");
  requireValue(password, "Trojan URI must include password.");

  const address = stripIpv6Brackets(parsedUrl.hostname);
  requireValue(address, "Trojan URI must include server address.");
  const port = parsePort(parsedUrl.port, "Trojan URI port");

  const params = parsedUrl.searchParams;
  const sni = firstParam(params, ["sni", "peer", "serverName"]) || address;
  const alpn = firstParam(params, ["alpn"]);
  const fp = firstParam(params, ["fp", "fingerprint"]);
  const method = normalizeSubscriptionTransport(
    firstParam(params, ["type", "network"]) || "tcp",
  );

  const streamSettings = {
    method,
    security: "tls",
    tlsSettings: {
      serverName: sni,
    },
  };

  if (fp) {
    streamSettings.tlsSettings.fingerprint = fp;
  }
  if (alpn) {
    streamSettings.tlsSettings.alpn = alpn.split(",").map((s) => s.trim()).filter(Boolean);
  }

  const pathValue = firstParam(params, ["path"]) || "/";
  const host = firstParam(params, ["host"]);

  if (method === "websocket") {
    streamSettings.wsSettings = { path: pathValue };
    if (host) {
      streamSettings.wsSettings.headers = { Host: host };
    }
  } else if (method === "grpc") {
    const serviceName = firstParam(params, ["serviceName"]) || pathValue.replace(/^\//, "");
    streamSettings.grpcSettings = { serviceName };
  }

  return {
    tag,
    protocol: "trojan",
    settings: {
      servers: [
        {
          address,
          port,
          password,
        },
      ],
    },
    streamSettings,
  };
}

function normalizeSubscriptionTransport(value) {
  switch (String(value).toLowerCase()) {
    case "tcp":
    case "raw":
      return "raw";
    case "ws":
    case "websocket":
      return "websocket";
    case "splithttp":
    case "xhttp":
      return "xhttp";
    case "grpc":
      return "grpc";
    case "httpupgrade":
      return "httpupgrade";
    default:
      throw new Error(`Unsupported transport: ${value}.`);
  }
}

function parseHostPort(hostPortStr) {
  let address = "";
  let port = 0;

  if (hostPortStr.startsWith("[")) {
    const closeBracket = hostPortStr.indexOf("]");
    if (closeBracket === -1) {
      throw new Error(`Invalid IPv6 host: ${hostPortStr}`);
    }
    address = hostPortStr.slice(1, closeBracket);
    const rest = hostPortStr.slice(closeBracket + 1);
    if (!rest.startsWith(":")) {
      throw new Error(`Missing port after IPv6 host: ${hostPortStr}`);
    }
    port = parsePort(rest.slice(1), "IPv6 port");
  } else {
    const colonIdx = hostPortStr.lastIndexOf(":");
    if (colonIdx === -1) {
      throw new Error(`Missing port in host:port string "${hostPortStr}"`);
    }
    address = hostPortStr.slice(0, colonIdx);
    port = parsePort(hostPortStr.slice(colonIdx + 1), "Server port");
  }

  return { address, port };
}

function normalizeTransport(value) {
  switch (value.toLowerCase()) {
    case "tcp":
    case "raw":
      return "raw";
    case "xhttp":
    case "splithttp":
      return "xhttp";
    case "grpc":
      return "grpc";
    case "ws":
    case "websocket":
      return "websocket";
    case "httpupgrade":
      return "httpupgrade";
    default:
      throw new Error(
        `Unsupported VLESS transport type=${value}; supported: tcp/raw, xhttp/splithttp, grpc, ws/websocket, httpupgrade.`,
      );
  }
}

function firstParam(params, names) {
  for (const name of names) {
    if (params.has(name)) {
      return params.get(name);
    }
  }
  return undefined;
}

function parsePort(value, name) {
  if (!/^\d+$/.test(value)) {
    throw new Error(`${name} must be a numeric TCP port.`);
  }

  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`${name} must be between 1 and 65535.`);
  }

  return port;
}

function parseBool(value, name) {
  const normalized = String(value).trim().toLowerCase();
  if (BOOL_TRUE.has(normalized)) {
    return true;
  }
  if (BOOL_FALSE.has(normalized)) {
    return false;
  }
  throw new Error(`${name} must be true or false.`);
}

function prepareOutputPath(outputPath) {
  const outputDir = path.dirname(outputPath);

  if (fs.existsSync(outputDir) && !fs.statSync(outputDir).isDirectory()) {
    throw new Error(`${outputDir} exists but is not a directory.`);
  }

  fs.mkdirSync(outputDir, { recursive: true });

  if (!fs.existsSync(outputPath)) {
    return;
  }

  const outputStat = fs.statSync(outputPath);
  if (outputStat.isDirectory()) {
    throw new Error(
      `${outputPath} is a directory. Stop Xray, remove that empty directory with "rmdir ${outputPath}", then run this renderer again.`,
    );
  }

  if (!outputStat.isFile()) {
    throw new Error(`${outputPath} exists but is not a regular file.`);
  }
}

function validateRealityPublicKey(value) {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error("REALITY pbk/public key must be unpadded base64url.");
  }

  const decoded = Buffer.from(value.replace(/-/g, "+").replace(/_/g, "/"), "base64");
  if (decoded.length !== 32) {
    throw new Error("REALITY pbk/public key must decode to exactly 32 bytes.");
  }
}

function validateRealityShortId(value) {
  if (value.length > 16) {
    throw new Error("REALITY sid/shortId must be at most 16 hex characters.");
  }

  if (value.length % 2 !== 0) {
    throw new Error("REALITY sid/shortId must contain an even number of hex characters.");
  }

  if (!/^[0-9a-fA-F]*$/.test(value)) {
    throw new Error("REALITY sid/shortId must contain only hex characters 0-9 and a-f.");
  }
}

function validateRealitySpiderX(value) {
  if (!value.startsWith("/")) {
    throw new Error("REALITY spx/spiderX must start with /.");
  }
}

function env(name, fallback) {
  return process.env[name] ?? fallback;
}

function requireValue(value, message) {
  if (value === undefined || value === null || value === "") {
    throw new Error(message);
  }
}

function stripIpv6Brackets(hostname) {
  if (hostname.startsWith("[") && hostname.endsWith("]")) {
    return hostname.slice(1, -1);
  }
  return hostname;
}

function loadDotEnv(filePath) {
  if (!fs.existsSync(filePath)) {
    return;
  }

  const lines = fs.readFileSync(filePath, "utf8").split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) {
      continue;
    }

    const separator = line.indexOf("=");
    if (separator < 1) {
      continue;
    }

    const key = line.slice(0, separator).trim();
    let value = line.slice(separator + 1).trim();

    if (
      (value.startsWith("'") && value.endsWith("'")) ||
      (value.startsWith('"') && value.endsWith('"'))
    ) {
      const quote = value[0];
      value = value.slice(1, -1);
      if (quote === '"') {
        value = value
          .replace(/\\n/g, "\n")
          .replace(/\\"/g, '"')
          .replace(/\\\\/g, "\\");
      }
    } else {
      value = value.replace(/\s+#.*$/, "");
    }

    if (process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
}
