#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const DEFAULT_CONFIG_PATH = "config/config.json";
const BOOL_TRUE = new Set(["1", "true", "yes", "y", "on"]);
const BOOL_FALSE = new Set(["0", "false", "no", "n", "off"]);
const REALITY_METHODS = new Set(["raw", "xhttp", "splithttp", "grpc"]);
const SUPPORTED_SECURITY = new Set(["none", "tls", "reality"]);

main();

function main() {
  try {
    loadDotEnv(".env");

    const outputPath = env("XRAY_CONFIG_PATH", DEFAULT_CONFIG_PATH);
    const config = buildConfig();
    prepareOutputPath(outputPath);
    fs.writeFileSync(outputPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o644 });
    fs.chmodSync(outputPath, 0o644);
    console.log(`Rendered Xray config to ${outputPath}`);
  } catch (error) {
    console.error(`Config render failed: ${error.message}`);
    process.exit(1);
  }
}

function buildConfig() {
  const parsed = parseVlessUri(requiredEnv("VLESS_URI"));
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

  return {
    log,
    inbounds,
    outbounds: [buildVlessOutbound(parsed)],
  };
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
    tag: "vless-out",
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
      throw new Error(`Unsupported VLESS transport type=${parsed.method}.`);
  }
}

function parseVlessUri(uri) {
  let parsedUrl;

  try {
    parsedUrl = new URL(uri.trim());
  } catch (error) {
    throw new Error(`VLESS_URI is not a valid URI: ${error.message}`);
  }

  if (parsedUrl.protocol !== "vless:") {
    throw new Error("VLESS_URI must start with vless://.");
  }

  const id = decodeURIComponent(parsedUrl.username);
  requireValue(id, "VLESS_URI must include the UUID/user ID before @.");

  const address = stripIpv6Brackets(parsedUrl.hostname);
  requireValue(address, "VLESS_URI must include a server address.");

  if (!parsedUrl.port) {
    throw new Error("VLESS_URI must include an explicit server port.");
  }

  const port = parsePort(parsedUrl.port, "VLESS_URI port");
  const params = parsedUrl.searchParams;
  const security = (firstParam(params, ["security"]) || "none").toLowerCase();
  if (!SUPPORTED_SECURITY.has(security)) {
    throw new Error(`Unsupported security=${security}; expected none, tls, or reality.`);
  }

  const method = normalizeTransport(firstParam(params, ["type", "method", "network"]) || "tcp");
  const encryption = firstParam(params, ["encryption"]) || "none";
  const flow = firstParam(params, ["flow"]) || "";

  return {
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

function requiredEnv(name) {
  const value = env(name, "");
  requireValue(value, `${name} is required.`);
  return value;
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
