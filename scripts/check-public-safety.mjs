#!/usr/bin/env node
/**
 * check-public-safety.mjs — guard against key material leaking into this repo.
 *
 * DS-mon is PUBLIC and ships as a Homebrew cask, so no private key, license
 * string or key-store path may ever be committed. Key management lives in the
 * separate private `personal_key_manager` repo; this app only reads its
 * exported metadata.
 *
 * Usage:
 *   node scripts/check-public-safety.mjs            # publish set: tracked + changed + new files
 *   node scripts/check-public-safety.mjs --tracked  # tracked files only (old behaviour)
 *   node scripts/check-public-safety.mjs --all      # every file on disk (skips ignored-path checks)
 *
 * Exit codes: 0 = clean, 1 = BLOCKER found, 2 = warnings only.
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const args = process.argv.slice(2);
const scanAll = args.includes("--all");
const trackedOnly = args.includes("--tracked");
const target = path.resolve(args.find((a) => !a.startsWith("--")) ?? path.join(__dirname, ".."));

/** Patterns that must never appear in this public repo. */
const BLOCKERS = [
  { name: "PEM private key", re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/ },
  { name: "Ed25519/X25519 JWK private scalar", re: /"d"\s*:\s*"[A-Za-z0-9_-]{43}"/ },
  { name: "TA1 license string", re: /TA1\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\./ },
  { name: "raw private key file", re: /^\s*[A-Za-z0-9_-]{43}\s*$/ },
  { name: "raw padded key file", re: /^\s*[A-Za-z0-9+/]{43}=\s*$/ },
  // 席位声明的密码校验器：pkm 只导出布尔值，真出现 scrypt$… 就是有人把值拄了出来。
  { name: "scrypt password verifier", re: /scrypt\$\d+\$\d+\$\d+\$[A-Za-z0-9_-]+\$[A-Za-z0-9_-]+/ },
  { name: "claim verifier field", re: /"pwdv"\s*:\s*"[^"]+"/ },
];

/** Suspicious but sometimes legitimate (placeholders, docs, paths, tests). */
const WARNINGS = [
  { name: "GitHub token", re: /\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/ },
  { name: "OpenAI-style key", re: /\bsk-[A-Za-z0-9-]{20,}/ },
  { name: "AWS access key id", re: /\bAKIA[0-9A-Z]{16}\b/ },
  { name: "Slack token", re: /\bxox[baprs]-[A-Za-z0-9-]{10,}/ },
  { name: "Hugging Face token", re: /\bhf_[A-Za-z0-9]{20,}/ },
  { name: "absolute home path", re: /\/Users\/[A-Za-z0-9._-]+\// },
  { name: "key-store path reference", re: /\b(dev-keys|frontdesk-keys|private\.key)\b/ },
  // 拓扑信息：仓库是公开的，真实主机名 / 隧道 ID 不该出现在这里（用占位符）
  { name: "real hostname / tailnet name", re: /\b[a-z0-9-]+\.(blackstonedsmon\.uk|tailb302ac\.ts\.net)\b/ },
  // 真实隧道标识：32 位十六进制 CNAME 目标，或与 tunnel/隧道 同行的 UUID
  { name: "real tunnel id", re: /\b[0-9a-f]{32}\.cfargotunnel\.com\b/i },
  {
    name: "real tunnel uuid",
    re: /(?=.*\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b)(?=.*(tunnel|隧道)).*/i,
  },
  // 长 base64 / base64url 块：不是密钥也可能是一次性导出物
  { name: "long base64 blob", re: /[A-Za-z0-9+/]{200,}={0,2}/ },
  { name: "long base64url blob", re: /[A-Za-z0-9_-]{200,}/ },
];

/**
 * Paths that must never be committed, regardless of file contents.
 * Only applied to the publish set — with --all, ignored directories exist on
 * disk by design and would false-positive.
 */
const PATH_BLOCKLIST = [
  /^docs\/safe\//,
  /^storage\//,
  /^logs\//,
  /^afrogene\//,
  /\.env$/,
  /\.env\.[A-Za-z]+$/,
  /\.key$/,
  /\.p12$/,
  /\.pem$/,
  /\.asc$/,
  /\.jks$/,
  /\.keystore$/,
  /(^|\/)config\.json$/,
];

/** Text-ish extensions worth reading; binary files are skipped. */
const TEXT_EXT = new Set([
  ".md", ".txt", ".json", ".jsonl", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx",
  ".swift", ".py", ".sh", ".bash", ".zsh", ".yml", ".yaml", ".toml", ".plist",
  ".html", ".css", ".sql", ".env", ".example", ".cfg", ".ini", ".gitignore", "",
  // 密钥容器：内容其实是文本，不列进来就永远不会被读到 —— 一份 TA1 就长这样。
  ".key", ".pem", ".asc", ".p12", ".jks", ".keystore",
]);

function gitTrackedFiles(dir) {
  try {
    return execFileSync("git", ["-C", dir, "ls-files", "-z"], {
      encoding: "buffer",
      stdio: ["ignore", "pipe", "ignore"],
    })
      .toString("utf8")
      .split("\0")
      .filter(Boolean);
  } catch {
    return null;
  }
}

/**
 * Every file that a `git commit` could include: tracked files plus staged,
 * unstaged and untracked-but-not-ignored paths. This is what the publish step
 * actually needs to review.
 */
function gitPublishSet(dir) {
  let raw;
  try {
    raw = execFileSync(
      "git",
      ["-C", dir, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
      { encoding: "buffer", stdio: ["ignore", "pipe", "ignore"] },
    ).toString("utf8");
  } catch {
    return null;
  }
  const files = new Set(gitTrackedFiles(dir) ?? []);
  const parts = raw.split("\0").filter(Boolean);
  for (let i = 0; i < parts.length; i++) {
    const entry = parts[i];
    if (entry.length < 4) continue;
    const status = entry.slice(0, 2);
    const p = entry.slice(3);
    if (status[0] === "R" || status[0] === "C") {
      // rename/copy: next token is the source path
      i++;
      files.add(p);
      continue;
    }
    files.add(p);
  }
  return [...files];
}

function walk(dir, acc = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === ".git" || entry.name === "node_modules" || entry.name === ".build") continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, acc);
    else acc.push(full);
  }
  return acc;
}

const rel = (p) => path.relative(target, p) || path.basename(p);

function main() {
  if (!fs.existsSync(target)) {
    console.error(`error: no such path: ${target}`);
    process.exit(2);
  }

  const tracked = scanAll ? null : trackedOnly ? gitTrackedFiles(target) : gitPublishSet(target);
  const candidates = tracked ?? walk(target).map((f) => path.relative(target, f));

  // 路径黑名单只对「会被提交的文件集」生效：--all 会扫到本就该被忽略的目录
  const pathBlocklistActive = !scanAll;
  const badPaths = [];
  if (pathBlocklistActive) {
    for (const f of candidates) {
      const normalized = f.split(path.sep).join("/");
      if (PATH_BLOCKLIST.some((re) => re.test(normalized))) badPaths.push(normalized);
    }
  }

  const files = candidates
    .map((f) => (path.isAbsolute(f) ? f : path.join(target, f)))
    .filter((f) => fs.existsSync(f))
    .filter((f) => TEXT_EXT.has(path.extname(f).toLowerCase()) || path.basename(f).startsWith(".env"))
    .filter((f) => {
      try {
        return fs.statSync(f).size < 2_000_000;
      } catch {
        return false;
      }
    });

  const blockers = [];
  const warnings = [];

  for (const file of files) {
    let text;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch {
      continue;
    }
    if (text.includes("\0")) continue; // binary
    // An ignore file legitimately *names* what it excludes — that is not a leak.
    const isIgnoreFile = path.basename(file) === ".gitignore";
    // The scanner and its CI workflow must name the very paths they enforce.
    const namesItsOwnRules =
      rel(file).endsWith("scripts/check-public-safety.mjs") ||
      rel(file).startsWith(".github/workflows/");
    for (const [i, line] of text.split("\n").entries()) {
      for (const { name, re } of BLOCKERS) {
        if (re.test(line)) blockers.push({ file: rel(file), line: i + 1, name, text: line.trim().slice(0, 120) });
      }
      for (const { name, re } of WARNINGS) {
        if (name === "key-store path reference" && (isIgnoreFile || namesItsOwnRules)) continue;
        if (re.test(line)) warnings.push({ file: rel(file), line: i + 1, name, text: line.trim().slice(0, 120) });
      }
    }
  }

  console.log(
    `scanning ${target}  (${
      tracked
        ? `${files.length} file(s) in the publish set`
        : `${files.length} file(s) on disk`
    })\n`,
  );

  if (badPaths.length > 0) {
    console.error(`BLOCKER — ${badPaths.length} file(s) in blocked paths:`);
    for (const p of badPaths) console.error(`  ${p}`);
    console.error("\nThese paths are either secrets or internal notes. Remove them from the index.");
    process.exit(1);
  }

  if (warnings.length > 0) {
    console.log(`WARN — ${warnings.length} suspicious match(es):`);
    for (const w of warnings) console.log(`  ${w.file}:${w.line}  [${w.name}]  ${w.text}`);
    console.log("");
  }

  if (blockers.length > 0) {
    console.error(`BLOCKER — ${blockers.length} match(es) must not be published:`);
    for (const b of blockers) console.error(`  ${b.file}:${b.line}  [${b.name}]  ${b.text}`);
    console.error("\nRefusing to pass. Remove the offending files before pushing.");
    process.exit(1);
  }

  console.log("BLOCKER check passed — 0 blocking matches.");
  if (warnings.length > 0) {
    console.log(`(${warnings.length} warning(s) above — review before pushing.)`);
    process.exit(2);
  }
}

main();
