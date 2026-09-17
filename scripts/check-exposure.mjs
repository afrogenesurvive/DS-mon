#!/usr/bin/env node
/**
 * DS-mon runtime exposure check.
 *
 * The repo-side scanners (check-public-safety.mjs, the save_progress step) only
 * look at *files*. This one asks the opposite question: **what is reachable from
 * the network right now, and does it answer without credentials?**
 *
 * It inspects four things:
 *   1. which ports the running app is listening on, and on which interface
 *   2. the Cloudflare tunnel's public hostnames (remote-managed → read via API)
 *   3. Tailscale serve vs funnel (funnel = public internet)
 *   4. an unauthenticated probe of every public URL that maps to one of our own
 *      ports — a 2xx there is a BLOCKER
 *
 * Usage:
 *   node scripts/check-exposure.mjs            # human-readable
 *   node scripts/check-exposure.mjs --json     # machine-readable
 *   node scripts/check-exposure.mjs --quiet    # only problems
 *
 * Exit codes: 0 = clean (warnings allowed), 1 = BLOCKER, 2 = warnings only.
 *
 * Note: the Cloudflare API token can only be read once DS-mon has stored one,
 * and it is only *read* here — never printed, never sent anywhere but
 * api.cloudflare.com.
 */
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const APP_PORTS = { 18080: "proxy", 18888: "sync" };
/** Paths that must NOT be reachable from the internet (admin / read surfaces). */
const SENSITIVE_PATHS = ["/sync/pull", "/events", "/api/queue-status", "/api/tasks", "/api/rules"];
/** A path must be probed with the method its handler expects — auth runs inside the route,
 *  so a GET against a POST-only route looks like "not matching" instead of "unauthorized". */
const PROBE_METHOD = { "/sync/push": "POST", "/license/check": "POST" };
const CF_API = "https://api.cloudflare.com/client/v4";
const TIMEOUT_MS = 12_000;

const args = process.argv.slice(2);
const asJson = args.includes("--json");
const quiet = args.includes("--quiet");
if (args.includes("--help") || args.includes("-h")) {
  console.log("usage: node scripts/check-exposure.mjs [--json] [--quiet]");
  process.exit(0);
}

const findings = [];
const info = [];
const add = (level, area, message, detail) =>
  findings.push({ level, area, message, ...(detail ? { detail } : {}) });

// ── 1. local listeners ───────────────────────────────────────────────────────
function localListeners() {
  let out = "";
  try {
    out = execFileSync("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return null; // lsof unavailable / no matches
  }
  const rows = [];
  for (const line of out.split("\n")) {
    const cols = line.trim().split(/\s+/);
    if (cols.length < 9) continue;
    const [command, , , , , , , , name] = cols;
    if (!/dev_mon|devmon/i.test(command) && !/dev_mon/i.test(line)) continue;
    const m = name.match(/^(.+):(\d+)$/);
    if (!m) continue;
    rows.push({ command, bind: m[1], port: Number(m[2]) });
  }
  return rows;
}

const listeners = localListeners();
if (listeners === null) {
  add("warn", "listeners", "could not run lsof — listener state is unknown");
} else if (listeners.length === 0) {
  add("warn", "listeners", "DS-mon is not running (no dev_mon listeners found)");
} else {
  for (const l of listeners) {
    const label = APP_PORTS[l.port] ? `${APP_PORTS[l.port]} port` : "port";
    const wildcard = l.bind === "*" || l.bind === "0.0.0.0" || l.bind === "::";
    if (wildcard) {
      add(
        "blocker",
        "listeners",
        `${label} ${l.port} is bound to ALL interfaces (${l.bind})`,
        "expected 127.0.0.1 — any device on the same network can reach it",
      );
    } else {
      info.push(`${label} ${l.port} bound to ${l.bind} (loopback-only)`);
    }
  }
}

// ── 2. secrets we need in order to read the cloud config ─────────────────────
function masterKey() {
  // Phase 2 moved the master key into the login Keychain; keep a file fallback
  // for machines that have not migrated yet.
  try {
    const b64 = execFileSync(
      "security",
      ["find-generic-password", "-s", "com.devmon.app", "-a", "master-key", "-w"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    const buf = Buffer.from(b64, "base64");
    if (buf.length === 32) return buf;
  } catch {
    /* fall through */
  }
  for (const p of [".dev-mon/.enc_key", ".ds-mon/.enc_key"]) {
    const file = path.join(os.homedir(), p);
    try {
      const buf = fs.readFileSync(file);
      if (buf.length === 32) return buf;
    } catch {
      /* keep looking */
    }
  }
  return null;
}

/** SecureStore stores AES-256-GCM as nonce(12) || ciphertext || tag(16). */
function decryptSealed(key, blob) {
  const nonce = blob.subarray(0, 12);
  const tag = blob.subarray(blob.length - 16);
  const ct = blob.subarray(12, blob.length - 16);
  const d = crypto.createDecipheriv("aes-256-gcm", key, nonce);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(ct), d.final()]).toString("utf8");
}

function appDefaults() {
  let xml;
  try {
    xml = execFileSync("defaults", ["export", "com.devmon.app", "-"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return null;
  }
  const str = (k) => {
    const m = xml.match(new RegExp(`<key>${k}</key>\\s*<string>([^<]*)</string>`));
    return m ? m[1] : null;
  };
  const data = (k) => {
    const m = xml.match(new RegExp(`<key>${k}</key>\\s*<data>([\\s\\S]*?)</data>`));
    return m ? Buffer.from(m[1].replace(/\s+/g, ""), "base64") : null;
  };
  return {
    account: str("cloudflare_account_id"),
    zone: str("cloudflare_zone_id"),
    tunnel: str("cloudflare_tunnel_id"),
    tokenBlob: data("cloudflare_api_token"),
  };
}

function cfToken() {
  const d = appDefaults();
  if (!d?.tokenBlob) return null;
  const key = masterKey();
  if (!key) return null;
  try {
    return decryptSealed(key, d.tokenBlob);
  } catch {
    return null;
  }
}

// ── 3. what the tunnel publishes ─────────────────────────────────────────────
async function cfJson(token, urlPath) {
  const res = await fetch(CF_API + urlPath, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  return res.json();
}

async function publicHostnames() {
  const token = cfToken();
  const d = appDefaults();
  if (!token || !d?.account || !d?.tunnel) {
    add(
      "warn",
      "cloudflare",
      "cannot read the tunnel config (no cloudflare token stored / not decryptable)",
      "run DS-mon once and configure the Cloudflare token in Settings → Services",
    );
    return [];
  }
  // Group by hostname: a hostname can now carry many path rules.
  const byHost = new Map();
  const cfg = await cfJson(token, `/accounts/${d.account}/cfd_tunnel/${d.tunnel}/configurations`);
  for (const rule of cfg?.result?.config?.ingress ?? []) {
    if (!rule.hostname) continue;   // catch-all
    if (!byHost.has(rule.hostname)) byHost.set(rule.hostname, { hostname: rule.hostname, rules: [] });
    byHost.get(rule.hostname).rules.push({ path: rule.path ?? "", service: rule.service ?? "" });
  }
  const out = [...byHost.values()];

  // Access policies are the only edge-side identity layer; report coverage.
  let accessDomains = new Set();
  if (d.account) {
    try {
      const apps = await cfJson(token, `/accounts/${d.account}/access/apps`);
      for (const a of apps?.result ?? []) {
        for (const dom of a.self_hosted_domains ?? []) accessDomains.add(dom);
        if (a.domain) accessDomains.add(a.domain);
      }
    } catch {
      /* token may lack the Access scope */
    }
  }
  for (const h of out) h.accessProtected = accessDomains.has(h.hostname);
  return out;
}

// ── 4. does a public URL answer without credentials? ─────────────────────────
async function probe(url, method = "GET", body = null) {
  try {
    const res = await fetch(url, {
      method,
      redirect: "manual",
      headers: body ? { "Content-Type": "application/json" } : undefined,
      body: body ?? undefined,
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    return { status: res.status, ok: true };
  } catch (e) {
    return { status: null, ok: false, error: e.name || String(e) };
  }
}

async function checkHostnames(hosts) {
  for (const h of hosts) {
    const target = `https://${h.hostname}`;
    const published = h.rules.map((r) => r.path || "/").join(", ");
    info.push(`${h.hostname} publishes: ${published}`);

    let sawAppOwned = false;
    const ownPaths = [];

    for (const rule of h.rules) {
      const port = (rule.service.match(/:(\d{2,5})/) ?? [])[1];
      const appOwned = port && APP_PORTS[Number(port)];
      if (!appOwned) continue;              // third-party service: no auth contract we can test
      sawAppOwned = true;
      ownPaths.push(rule.path);

      const method = PROBE_METHOD[rule.path] ?? "GET";
      const url = target + (rule.path || "/");
      const r = await probe(url, method, method === "POST" ? "{}" : null);
      const label = `${method} ${rule.path || "/"}`;

      if (!r.ok) {
        add("warn", "cloudflare", `${h.hostname}: ${label} unreachable (${r.error})`,
            "tunnel may be down — not a security finding, but the check is incomplete");
      } else if (r.status >= 200 && r.status < 300) {
        add("blocker", "cloudflare",
            `${url} answered ${r.status} WITHOUT credentials`,
            `${APP_PORTS[Number(port)]} is publicly readable through this path`);
      } else if (r.status === 401 || r.status === 403) {
        info.push(`${h.hostname}: ${label} → ${r.status} (token enforced)`);
      } else if (r.status === 404) {
        // A rule exists in the config for this path, yet the edge fell through to the
        // catch-all. That is the signature of a path that does not actually match —
        // e.g. a pasted zero-width space — and the endpoint is silently dead.
        add("warn", "cloudflare",
            `${h.hostname}: rule "${rule.path}" is published but that path returns an edge 404`,
            "the rule does not match anything — check for an invisible character (U+200B) or a typo in the path");
      } else if (r.status === 502 || r.status === 503 || r.status === 504) {
        info.push(`${h.hostname}: ${label} → ${r.status} (rule matched, origin unreachable)`);
      } else {
        add("warn", "cloudflare", `${h.hostname} answered ${r.status} to ${label}`,
            "expected 401/403 — verify by hand");
      }
    }

    // Paths that should never be public, whichever hostname serves them.
    for (const p of SENSITIVE_PATHS) {
      if (ownPaths.includes(p)) continue;   // already covered above
      const r = await probe(target + p, "GET", null);
      if (!r.ok) continue;
      if (r.status >= 200 && r.status < 300) {
        add("blocker", "cloudflare", `${target}${p} answered ${r.status} WITHOUT credentials`,
            "this is an admin/read surface that should not be published at all");
      } else if (r.status === 502 || r.status === 503 || r.status === 504) {
        add("warn", "cloudflare", `${target}${p} is still published (origin currently down)`,
            "the rule matches, so it will be exposed as soon as the service is running");
      } else if (r.status === 401 || r.status === 403) {
        add("warn", "cloudflare", `${target}${p} is published and gated only by the app`,
            "prefer not publishing it at all (path-scope the ingress)");
      }
      // 404 = not published: that is the desired state.
    }

    if (!h.accessProtected && sawAppOwned) {
      add("warn", "cloudflare", `${h.hostname} has no Cloudflare Access policy`,
          "app-level bearer token is the only gate; consider putting the hostname behind Access");
    }
  }
}

// ── 5. Tailscale: serve is tailnet-only, funnel is the internet ──────────────
function tailscaleMappings() {
  const run = (sub) => {
    try {
      return JSON.parse(
        execFileSync("tailscale", [sub, "status", "--json"], {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
        }) || "{}",
      );
    } catch {
      return null;
    }
  };
  const serve = run("serve");
  if (!serve) return null;
  const allowFunnel = serve.AllowFunnel ?? {};
  const mappings = [];
  for (const [port, tcp] of Object.entries(serve.TCP ?? {})) {
    const hostPort = Object.keys(serve.Web ?? {}).find((k) => k.endsWith(`:${port}`)) ?? "";
    const handlers = serve.Web?.[hostPort]?.Handlers ?? {};
    for (const [p, handler] of Object.entries(handlers)) {
      const target = handler.Proxy ?? handler.Text ?? "";
      const dns = hostPort.replace(/:\d+$/, "");
      mappings.push({
        port: Number(port),
        scheme: tcp.HTTPS ? "https" : "http",
        dns,
        path: p,
        target,
        isFunnel: allowFunnel[hostPort] !== undefined || Object.keys(allowFunnel).some((k) => k.endsWith(`:${port}`)),
      });
    }
  }
  return mappings;
}

async function checkTailscale() {
  const mappings = tailscaleMappings();
  if (mappings === null) {
    info.push("tailscale CLI not available — serve/funnel not checked");
    return;
  }
  if (mappings.length === 0) {
    info.push("tailscale: no serve/funnel mappings");
    return;
  }
  for (const m of mappings) {
    const url = `${m.scheme}://${m.dns}:${m.port}${m.path === "/" ? "" : m.path}`;
    const appPort = (m.target.match(/:(\d{2,5})/) ?? [])[1];
    const appOwned = appPort && APP_PORTS[Number(appPort)];
    if (!m.isFunnel) {
      info.push(`tailscale serve ${url} → ${m.target} (tailnet only)`);
      continue;
    }
    if (!appOwned) {
      add("warn", "tailscale", `funnel ${url} → ${m.target}`,
          "public funnel to a non-app service — no auth probe possible");
      continue;
    }
    const spec = probeFor(m.target);
    const r = await probe(url + spec.url, spec.method, spec.body);
    if (r.ok && r.status >= 200 && r.status < 300) {
      add("blocker", "tailscale",
          `funnel ${url}${spec.url} answered ${r.status} WITHOUT credentials`,
          "funnel is the open internet — this must be token-gated");
    } else if (r.ok) {
      info.push(`tailscale funnel ${url}: ${spec.name} → ${r.status}`);
    }
  }
}

// ── run ──────────────────────────────────────────────────────────────────────
const hosts = await publicHostnames();
await checkHostnames(hosts);
await checkTailscale();

const blockers = findings.filter((f) => f.level === "blocker");
const warnings = findings.filter((f) => f.level === "warn");
const exitCode = blockers.length ? 1 : warnings.length ? 2 : 0;

if (asJson) {
  console.log(JSON.stringify({ exitCode, blockers, warnings, info, hostnames: hosts }, null, 2));
} else {
  if (!quiet || blockers.length || warnings.length) {
    console.log("DS-mon exposure check\n");
    console.log(`  public hostnames: ${hosts.length ? hosts.map((h) => h.hostname).join(", ") : "(none)"}`);
    console.log(`  listeners: ${listeners?.length ?? 0}`);
    console.log("");
  }
  if (!quiet) for (const i of info) console.log(`  · ${i}`);
  for (const b of blockers) {
    console.log(`\n  [BLOCKER] ${b.area}: ${b.message}`);
    if (b.detail) console.log(`            ${b.detail}`);
  }
  for (const w of warnings) {
    console.log(`\n  [WARN] ${w.area}: ${w.message}`);
    if (w.detail) console.log(`         ${w.detail}`);
  }
  console.log(
    `\n${blockers.length} blocker(s), ${warnings.length} warning(s) — exit ${exitCode}`,
  );
  if (blockers.length) {
    console.log("\nDo not publish anything until the blockers above are resolved.");
  }
}
process.exit(exitCode);
