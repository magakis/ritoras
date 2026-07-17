#!/usr/bin/env node

// scripts/deploy-ipa.mjs — GitHub deploy pipeline for Ritoras iOS keyboard extension
// Zero-dependency Node.js ES module. Built-in modules only: node:fs, node:path,
// node:child_process, node:os, node:url
//
// Downloads Ritoras.ipa artifacts from GitHub Actions, stores them in a
// versioned build history under ~/.local/share/ritoras/builds/<runId>/, and
// serves them over HTTP via SideStore's custom-scheme handler. The version
// history persists builds across sessions so a broken latest build can be
// rolled back on the phone — each build has a meta.json with run number,
// commit SHA, branch, message, author, and size.
//
// CLI entry points: download [runId], serve, list, list-remote [count],
// deploy, refresh, push, wait [sha], prune

import { execSync } from 'node:child_process';
import { createServer } from 'node:http';
import {
  readFileSync,
  writeFileSync,
  unlinkSync,
  mkdirSync,
  existsSync,
  statSync,
  createReadStream,
  readdirSync,
  renameSync,
  rmSync,
  copyFileSync,
} from 'node:fs';
import { join } from 'node:path';
import { tmpdir, networkInterfaces, homedir } from 'node:os';

const REPO = 'magakis/ritoras';
const BRANCH = 'main';
const ARTIFACT_NAME = 'Ritoras.ipa';
const TOKEN_PATH = '/home/michael/.config/opencode/gh-token';
const DEPLOY_DIR = '/tmp/ritoras-deploy';
const BUNDLE_ID = 'com.ritoras.app';
const REPO_DIR = '/home/michael/IT/ritoras';
// Persistent build store — XDG data dir (~/.local/share/ritoras/builds), NOT /tmp.
// /tmp is ephemeral (wiped on reboot), defeating the version-history feature.
// ~/.local/share/ mirrors the convention used for gh-token. Override via
// RITORAS_BUILDS_DIR env var.
const BUILDS_DIR =
  process.env.RITORAS_BUILDS_DIR || join(homedir(), '.local/share/ritoras/builds');
// Count-based retention (default 10) instead of age-based. The .ipa is
// hundreds of KB; 10 builds is trivial disk. Bounds predictable without
// date arithmetic. Matches "keep the last few in case the latest is broken".
// Override via RITORAS_KEEP_BUILDS env var.
const KEEP_BUILDS = parseInt(process.env.RITORAS_KEEP_BUILDS || '10', 10);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function readToken() {
  try {
    return readFileSync(TOKEN_PATH, 'utf8').trim();
  } catch (err) {
    throw new Error(`Failed to read token from ${TOKEN_PATH}: ${err.message}`);
  }
}

async function ghApi(path, options = {}) {
  const token = readToken();
  const headers = {
    ...(options.headers || {}),
    Authorization: `Bearer ${token}`,
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'ritoras-deploy',
  };
  const url = `https://api.github.com${path}`;
  const response = await fetch(url, { ...options, headers });
  if (!response.ok) {
    const body = await response.text();
    throw new Error(
      `GitHub API ${response.status} ${response.statusText}: ${path}\n${body}`,
    );
  }
  return response.json();
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function detectReachableIPs() {
  const ifaces = networkInterfaces();
  const ips = [];

  for (const name of Object.keys(ifaces)) {
    for (const iface of ifaces[name]) {
      if (iface.internal || iface.family !== 'IPv4') continue;
      const ip = iface.address;
      if (ip.startsWith('127.')) continue;

      let type;
      if (ip.startsWith('100.')) {
        type = 'tailscale';
      } else if (
        ip.startsWith('192.168.') ||
        ip.startsWith('10.') ||
        (ip.startsWith('172.') &&
          parseInt(ip.split('.')[1], 10) >= 16 &&
          parseInt(ip.split('.')[1], 10) <= 31)
      ) {
        type = 'lan';
      } else {
        type = 'other';
      }

      ips.push({ ip, type });
    }
  }

  const order = { tailscale: 0, lan: 1, other: 2 };
  ips.sort((a, b) => order[a.type] - order[b.type]);

  return ips;
}

function shortSha(sha) {
  return sha.slice(0, 7);
}

function formatBytes(n) {
  // 1 decimal place, binary units (KiB/MiB/GiB)
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

// Keys builds by workflow run ID (integer) — unique, stable, monotonic, no
// name collisions or parsing ambiguity. Already provided by the GitHub runs
// API; no need to synthesize a version string. Numeric sort (descending)
// trivially orders newest first.
function versionDir(runId) {
  return join(BUILDS_DIR, String(runId));
}

function readMeta(buildDir) {
  try {
    return JSON.parse(readFileSync(join(buildDir, 'meta.json'), 'utf8'));
  } catch {
    return null;
  }
}

function writeMeta(buildDir, meta) {
  writeFileSync(join(buildDir, 'meta.json'), JSON.stringify(meta, null, 2));
}

// Scan-on-request: readdir + parse each meta.json. No central manifest or DB.
// Self-healing — deleting a dir removes the build entirely; no manifest to
// desync. For ≤10 builds the scan is sub-ms; no cache needed. Consistent
// with zero-dependency design. If N grows large: add an in-memory cache
// keyed on BUILDS_DIR mtime (future work, not needed now).
function listVersions() {
  let entries;
  try {
    entries = readdirSync(BUILDS_DIR);
  } catch {
    return [];
  }
  const builds = entries
    .map((entry) => readMeta(versionDir(entry)))
    .filter(Boolean);
  builds.sort((a, b) => b.runId - a.runId);
  return builds;
}

function runRetention() {
  const builds = listVersions();
  if (builds.length <= KEEP_BUILDS) return;
  const overflow = builds.slice(KEEP_BUILDS);
  for (const v of overflow) {
    rmSync(versionDir(v.runId), { recursive: true, force: true });
    console.log(`🗑️  Pruned old build ${v.runNumber} (${v.shortSha})`);
  }
}

// ---- Phase 2 helpers ------------------------------------------------------

function resolveLatest() {
  const v = listVersions();
  return v.length ? v[0] : null;
}

function findVersion(runId) {
  return listVersions().find(v => String(v.runId) === String(runId)) ?? null;
}

// Streams .ipa bytes directly (createReadStream + pipe), never a 302 redirect.
// SideStore's install?url= custom-scheme handler may not follow redirects.
// All .ipa routes use this function to guarantee SideStore compatibility.
//
// The res.on('close') handler destroys the stream on disconnect. If the HTTP
// client drops mid-stream (network loss, cancel), Node keeps the fd open
// until process exit — on a long-running server serving many .ipa files this
// would exhaust fds. The !stream.destroyed guard prevents double-destroy
// when the stream ended naturally before the close event fired.
function streamIpa(version, res, label, onActivity) {
  res.writeHead(200, {
    'Content-Type': 'application/octet-stream',
    'Content-Disposition': 'attachment; filename="Ritoras.ipa"',
    'Content-Length': String(version.sizeBytes),
  });
  const stream = createReadStream(join(versionDir(version.runId), version.fileName || 'Ritoras.ipa'));
  res.on('close', () => {
    if (!stream.destroyed) {
      stream.destroy();
    }
  });
  stream.on('error', err => {
    console.error('Stream error:', err.message);
    if (!res.headersSent) res.writeHead(500);
    res.end('Internal error');
  });
  stream.pipe(res);
  stream.on('end', () => {
    if (typeof onActivity === 'function') onActivity();
    console.log(`✅ ${label} downloaded (${version.shortSha})`);
  });
}

function renderIndexPage(versions, host) {
  const latest = versions[0];

  function fmtDate(d) {
    try { return new Date(d).toLocaleString(); } catch { return d || ''; }
  }

  function truncate(s, n = 80) {
    if (!s) return '';
    return s.length > n ? s.slice(0, n) + '\u2026' : s;
  }

  // Sanitizes untrusted metadata from GitHub commit data — commit messages,
  // author names, branch names. A malicious or accidental <script> in a
  // commit message would execute in the browser. Applied to every untrusted
  // field in renderIndexPage. Escapes & first — critical, otherwise &lt;
  // becomes &amp;lt;.
  function escapeHtml(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  let prevHtml = '';
  if (versions.length > 1) {
    prevHtml = '<h2 class="section-heading">Previous versions</h2>';
    for (const v of versions.slice(1)) {
      prevHtml += '<div class="version-row">\n    <div class="version-info">\n      <strong>#' + escapeHtml(v.runNumber) + '</strong> \u2022 <code>' + escapeHtml(v.shortSha) + '</code> \u2022 ' + escapeHtml(fmtDate(v.builtAt)) + ' \u2022 ' + escapeHtml(v.sizeHuman) + '\n      <div class="commit">' + escapeHtml(truncate(v.commitMessage)) + '</div>\n    </div>\n    <div class="version-actions">\n      <a class="btn btn-secondary" href="sidestore://install?url=http://' + escapeHtml(host) + '/v/' + escapeHtml(v.runId) + '/Ritoras.ipa">Install</a>\n      <a class="btn btn-secondary btn-muted" href="/v/' + escapeHtml(v.runId) + '/Ritoras.ipa">Download</a>\n    </div>\n  </div>';
    }
  }

  return '<!DOCTYPE html>\n<html>\n<head>\n  <meta charset="utf-8">\n  <meta name="viewport" content="width=device-width, initial-scale=1">\n  <title>Ritoras Install</title>\n  <style>\n    * { margin: 0; padding: 0; box-sizing: border-box; }\n    body {\n      font-family: -apple-system, BlinkMacSystemFont, sans-serif;\n      display: flex;\n      flex-direction: column;\n      align-items: center;\n      justify-content: center;\n      min-height: 100vh;\n      padding: 24px;\n      background: #f5f5f7;\n      color: #1d1d1f;\n    }\n    @media (prefers-color-scheme: dark) {\n      body {\n        background: #1c1c1e;\n        color: #f5f5f7;\n      }\n    }\n    .container {\n      width: 100%;\n      max-width: 480px;\n      text-align: center;\n    }\n    h1 {\n      font-size: 28px;\n      font-weight: 700;\n      margin-bottom: 8px;\n    }\n    .subtitle {\n      font-size: 16px;\n      color: #6e6e73;\n      margin-bottom: 32px;\n    }\n    @media (prefers-color-scheme: dark) {\n      .subtitle {\n        color: #98989d;\n      }\n    }\n    .btn {\n      display: block;\n      width: 100%;\n      padding: 14px 20px;\n      font-size: 17px;\n      font-family: inherit;\n      border-radius: 12px;\n      text-decoration: none;\n      text-align: center;\n      -webkit-tap-highlight-color: transparent;\n      transition: opacity 0.2s;\n    }\n    .btn:active {\n      opacity: 0.7;\n    }\n    .btn-primary {\n      background: #007aff;\n      color: #fff;\n      font-weight: 600;\n      margin-bottom: 12px;\n    }\n    .btn-secondary {\n      background: transparent;\n      color: #007aff;\n      border: 1.5px solid #007aff;\n      font-weight: 500;\n      margin-bottom: 12px;\n    }\n    @media (prefers-color-scheme: dark) {\n      .btn-primary {\n        background: #0a84ff;\n      }\n      .btn-secondary {\n        color: #0a84ff;\n        border-color: #0a84ff;\n      }\n    }\n    .btn-muted {\n      color: #6e6e73;\n      border-color: #d2d2d7;\n    }\n    @media (prefers-color-scheme: dark) {\n      .btn-muted {\n        color: #98989d;\n        border-color: #48484a;\n      }\n    }\n    .badge {\n      display: inline-block;\n      background: #007aff;\n      color: #fff;\n      font-size: 12px;\n      font-weight: 600;\n      padding: 3px 10px;\n      border-radius: 10px;\n      margin-bottom: 16px;\n    }\n    @media (prefers-color-scheme: dark) {\n      .badge {\n        background: #0a84ff;\n      }\n    }\n    .section-heading {\n      margin-top: 32px;\n      margin-bottom: 16px;\n      font-size: 20px;\n      font-weight: 600;\n      text-align: left;\n    }\n    .version-row {\n      display: flex;\n      align-items: center;\n      justify-content: space-between;\n      padding: 12px 0;\n      border-top: 1px solid #d2d2d7;\n      gap: 12px;\n    }\n    @media (prefers-color-scheme: dark) {\n      .version-row {\n        border-top-color: #48484a;\n      }\n    }\n    .version-info {\n      text-align: left;\n      font-size: 14px;\n      line-height: 1.4;\n      min-width: 0;\n    }\n    .version-actions {\n      display: flex;\n      gap: 8px;\n      flex-shrink: 0;\n    }\n    .version-info .commit {\n      color: #6e6e73;\n      font-size: 13px;\n      overflow: hidden;\n      text-overflow: ellipsis;\n      white-space: nowrap;\n      max-width: 260px;\n    }\n    @media (prefers-color-scheme: dark) {\n      .version-info .commit {\n        color: #98989d;\n      }\n    }\n    .version-actions .btn {\n      width: auto;\n      padding: 8px 16px;\n      font-size: 14px;\n      margin-bottom: 0;\n    }\n    .note {\n      margin-top: 24px;\n      font-size: 13px;\n      color: #6e6e73;\n    }\n    @media (prefers-color-scheme: dark) {\n      .note {\n        color: #98989d;\n      }\n    }\n  </style>\n</head>\n<body>\n  <div class="container">\n    <h1>Ritoras</h1>\n    <p class="subtitle">Build #' + escapeHtml(latest.runNumber) + ' \u2022 ' + escapeHtml(latest.shortSha) + ' \u2022 ' + escapeHtml(fmtDate(latest.builtAt)) + '</p>\n    <span class="badge">Latest</span>\n    <a class="btn btn-primary" href="sidestore://install?url=http://' + escapeHtml(host) + '/Ritoras.ipa">Install via SideStore</a>\n    <a class="btn btn-secondary" href="sidestore://">Open SideStore</a>\n    <a class="btn btn-secondary btn-muted" href="/Ritoras.ipa">Download .ipa</a>\n    ' + prevHtml + '\n  </div>\n</body>\n</html>';
}

// ---------------------------------------------------------------------------
// Subcommands
// ---------------------------------------------------------------------------

async function push() {
  const token = readToken();
  const tmpHelper = join(tmpdir(), `git-credential-helper-${Date.now()}.sh`);

  try {
    writeFileSync(
      tmpHelper,
      '#!/bin/sh\n' +
        'echo "protocol=https"\n' +
        'echo "host=github.com"\n' +
        'echo "username=x-access-token"\n' +
        `echo "password=${token}"\n`,
      { mode: 0o500 },
    );

    const sha = execSync('git rev-parse HEAD', {
      cwd: REPO_DIR,
      encoding: 'utf8',
    }).trim();

    execSync(`git -c credential.helper="${tmpHelper}" push origin ${BRANCH}`, {
      cwd: REPO_DIR,
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
      stdio: 'inherit',
    });

    console.log(`Pushed ${sha}`);
    return sha;
  } finally {
    try {
      unlinkSync(tmpHelper);
    } catch {
      // best-effort cleanup
    }
  }
}

async function wait(sha) {
  if (!sha) {
    sha = execSync('git rev-parse HEAD', {
      cwd: REPO_DIR,
      encoding: 'utf8',
    }).trim();
  }

  const timeout = 15 * 60 * 1000; // 15 minutes
  const start = Date.now();

  // Stage 1: wait for the workflow run to appear (CI trigger delay)
  let run = null;
  while (Date.now() - start < timeout) {
    const data = await ghApi(
      `/repos/${REPO}/actions/runs?head_sha=${sha}&per_page=1`,
    );
    if (data.total_count > 0) {
      run = data.workflow_runs[0];
      console.log(`Found workflow run #${run.id} (status: ${run.status})`);
      break;
    }
    await sleep(10000);
  }

  if (!run) {
    throw new Error('Timed out waiting for workflow run to appear');
  }

  // Stage 2: wait for the run to complete
  while (Date.now() - start < timeout) {
    const updated = await ghApi(`/repos/${REPO}/actions/runs/${run.id}`);
    if (updated.status === 'completed') {
      if (updated.conclusion === 'success') {
        console.log(`Build succeeded: ${updated.html_url}`);
        return;
      }
      throw new Error(
        `Build failed (${updated.conclusion}): ${updated.html_url}`,
      );
    }
    await sleep(15000);
  }

  throw new Error('Timed out waiting for build to complete');
}

async function download(runId) {
  mkdirSync(DEPLOY_DIR, { recursive: true });

  let run;
  if (runId) {
    run = await ghApi(`/repos/${REPO}/actions/runs/${runId}`);
  } else {
    // Find the latest successful workflow run
    const data = await ghApi(
      `/repos/${REPO}/actions/runs?per_page=1&status=success`,
    );
    if (data.total_count === 0) {
      throw new Error('No successful workflow runs found');
    }
    run = data.workflow_runs[0];
  }

  // Locate the Ritoras.ipa artifact
  const artifactsData = await ghApi(
    `/repos/${REPO}/actions/runs/${run.id}/artifacts`,
  );
  const artifact = artifactsData.artifacts.find(
    (a) => a.name === ARTIFACT_NAME,
  );
  if (!artifact) {
    throw new Error(
      `Artifact "${ARTIFACT_NAME}" not found in run ${run.id}`,
    );
  }
  if (artifact.expired) {
    throw new Error(`Artifact "${ARTIFACT_NAME}" has expired`);
  }

  const meta = {
    runId: run.id,
    runNumber: run.run_number,
    sha: run.head_sha,
    shortSha: shortSha(run.head_sha),
    branch: run.head_branch,
    commitMessage: (run.head_commit?.message || '').split('\n')[0],
    author: run.head_commit?.author?.name ?? null,
    builtAt: run.run_started_at,
    downloadedAt: new Date().toISOString(),
    artifactName: ARTIFACT_NAME,
    fileName: ARTIFACT_NAME,
    sizeBytes: artifact.size_in_bytes,
    sizeHuman: formatBytes(artifact.size_in_bytes),
    source: 'github-actions',
  };

  // Idempotency guard: meta.json is the LAST thing written on a successful
  // store. Its presence means the build is complete on disk — skip the
  // multi-MB artifact download entirely. A partial dir without meta.json is
  // treated as absent and re-downloaded.
  if (existsSync(join(versionDir(meta.runId), 'meta.json'))) {
    console.log(`Build ${meta.runNumber} (${meta.shortSha}) already on disk, skipping.`);
    return;
  }

  console.log(
    `Downloading ${ARTIFACT_NAME} (${artifact.size_in_bytes} bytes)...`,
  );

  // Download the artifact zip (follows redirect to signed URL)
  const token = readToken();
  const dlResponse = await fetch(artifact.archive_download_url, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!dlResponse.ok) {
    const body = await dlResponse.text();
    throw new Error(
      `Download failed: ${dlResponse.status} ${dlResponse.statusText}\n${body}`,
    );
  }

  const zipPath = join(DEPLOY_DIR, 'artifact.zip');
  const buffer = Buffer.from(await dlResponse.arrayBuffer());
  writeFileSync(zipPath, buffer);

  // Extract using python3 (unzip is not installed on the runner)
  execSync(
    `python3 -c "import zipfile; zipfile.ZipFile('${zipPath}').extractall('${DEPLOY_DIR}')"`,
    { stdio: 'inherit' },
  );

  const ipaPath = join(DEPLOY_DIR, ARTIFACT_NAME);
  if (!existsSync(ipaPath)) {
    throw new Error(`Extracted ${ARTIFACT_NAME} not found at ${ipaPath}`);
  }

  const dest = versionDir(meta.runId);
  mkdirSync(dest, { recursive: true });
  // renameSync is atomic and instant but FAILS across filesystem boundaries.
  // The scratch dir (DEPLOY_DIR) is on /tmp; builds dir is under $HOME —
  // often different filesystems. copyFileSync + unlinkSync handles the
  // cross-filesystem case at the cost of a brief copy.
  try {
    renameSync(ipaPath, join(dest, ARTIFACT_NAME));
  } catch {
    copyFileSync(ipaPath, join(dest, ARTIFACT_NAME));
    unlinkSync(ipaPath);
  }
  const { size } = statSync(join(dest, ARTIFACT_NAME));
  meta.sizeBytes = size;
  meta.sizeHuman = formatBytes(size);
  writeMeta(dest, meta);
  runRetention();
  console.log(`✅ Build ${meta.runNumber} (${meta.shortSha}) stored at ${dest} (${meta.sizeHuman})`);
}

async function listRemote(count) {
  const perPage = Math.min(count || 5, 100);
  const data = await ghApi(
    `/repos/${REPO}/actions/runs?per_page=${perPage}&status=success`,
  );
  const runs = data.workflow_runs;
  if (!runs || runs.length === 0) {
    console.log('No remote builds found.');
    return;
  }

  const h1 = 'runId', h2 = 'runNumber', h3 = 'shortSha', h4 = 'createdAt', h5 = 'commitMessage';
  console.log(`${h1.padEnd(14)} ${h2.padEnd(12)} ${h3.padEnd(10)} ${h4.padEnd(26)} ${h5}`);
  console.log(`${'─'.repeat(13)} ${'─'.repeat(11)} ${'─'.repeat(9)} ${'─'.repeat(25)} ${'─'.repeat(30)}`);
  for (const r of runs) {
    const sha = shortSha(r.head_sha);
    const msg = (r.head_commit?.message || '').split('\n')[0];
    const msgTrunc = msg.length > 80 ? msg.slice(0, 80) + '\u2026' : msg;
    console.log(
      `${String(r.id).padEnd(14)} ${String(r.run_number).padEnd(12)} ${sha.padEnd(10)} ${(r.run_started_at || '').padEnd(26)} ${msgTrunc}`,
    );
  }
}

async function deploy() {
  const sha = await push();
  await wait(sha);
  await download();
  await serve();
}

async function refresh() {
  await download();
  await serve();
}

async function serve() {
  if (listVersions().length === 0) {
    console.error("No .ipa found. Run 'download' or 'refresh' first.");
    process.exit(1);
  }

  let lastActivityAt = Date.now();

  // Routes:
  //   GET /                            Landing page — list all versions, newest first
  //   GET /Ritoras.ipa                 Latest build (backward-compat: existing SideStore bookmarks)
  //   GET /latest/Ritoras.ipa          Alias for the above (explicit)
  //   GET /v/<runId>/Ritoras.ipa       Specific historical build by workflow run ID
  //   *                                404
  //
  // All .ipa routes stream directly (no 302) for SideStore custom-scheme compatibility.
  const server = createServer((req, res) => {
    lastActivityAt = Date.now();
    const path = req.url;

    if (req.method === 'GET' && path === '/') {
      const detected = detectReachableIPs();
      const host = req.headers.host || (detected[0] ? `${detected[0].ip}:${port}` : `localhost:${port}`);
      const versions = listVersions();
      if (versions.length === 0) {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ritoras</title></head><body style="font-family:-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#f5f5f7;color:#1d1d1f"><p>No builds available yet.</p></body></html>');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(renderIndexPage(versions, host));
    } else if (req.method === 'GET' && (path === '/Ritoras.ipa' || path === '/latest/Ritoras.ipa')) {
      const v = resolveLatest();
      if (!v) {
        res.writeHead(404);
        res.end('No .ipa found');
        return;
      }
      streamIpa(v, res, 'latest', () => { lastActivityAt = Date.now(); });
    } else if (req.method === 'GET') {
      const m = path.match(/^\/v\/(\d+)\/Ritoras\.ipa$/);
      if (m) {
        const v = findVersion(m[1]);
        if (!v) {
          res.writeHead(404);
          res.end('Version not found');
          return;
        }
        streamIpa(v, res, 'v' + v.runNumber, () => { lastActivityAt = Date.now(); });
        return;
      }
      res.writeHead(404);
      res.end('Not found');
    } else {
      res.writeHead(404);
      res.end('Not found');
    }
  });

  // Find a free port between 8765 and 8770
  let port = 8765;
  for (; port <= 8770; port++) {
    try {
      await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, '0.0.0.0', () => {
          server.removeListener('error', reject);
          resolve();
        });
      });
      break;
    } catch (err) {
      if (err.code === 'EADDRINUSE') {
        if (port === 8770) {
          throw new Error('Could not find a free port (tried 8765-8770)');
        }
        continue;
      }
      throw err;
    }
  }

  if (port !== 8765) {
    console.log(`Port 8765 in use, using port ${port}`);
  }

  const ips = detectReachableIPs();
  console.log('📱 Open this URL on your iPhone Safari:');
  for (const { ip } of ips) {
    console.log(`   http://${ip}:${port}/`);
  }
  // Inactivity-based shutdown replaces the original "close after first
  // download" behavior. Version history requires the server to survive across
  // downloads — try latest, if broken grab the previous. Inactivity timeout
  // is a strict superset: serves single-install (shuts down after idle) and
  // multi-download (stays alive during active use). Override via
  // RITORAS_IDLE_TIMEOUT_MIN (default 15 min).
  const IDLE_TIMEOUT_MS =
    parseInt(process.env.RITORAS_IDLE_TIMEOUT_MIN || '15', 10) * 60_000;
  console.log(`⏱️  Server will shut down after ${Math.round(IDLE_TIMEOUT_MS / 60000)} min of inactivity.`);

  while (true) {
    await sleep(1000);
    if (Date.now() - lastActivityAt > IDLE_TIMEOUT_MS) {
      console.log(`⏱️  No activity for ${Math.round(IDLE_TIMEOUT_MS / 60000)} min. Shutting down.`);
      server.close();
      return;
    }
  }
}

// ---------------------------------------------------------------------------
// CLI Dispatch
// ---------------------------------------------------------------------------

// CLI subcommands:
//   push              Trigger a GitHub Actions build and wait for the artifact
//   wait [sha]        Wait for an in-progress build to finish
//   download [runId]  Download latest (or specific <runId>) artifact into the versioned store
//   deploy            Download latest + serve (convenience combo)
//   refresh           Re-download latest (replaces cached) + serve
//   serve             Start the HTTP server (reads from the versioned store)
//   list              List locally-stored builds
//   list-remote [n]   List last n (default 5) successful runs from GitHub
//   prune             Remove old builds beyond KEEP_BUILDS
const subcommand = process.argv[2];

try {
  switch (subcommand) {
    case 'push':
      await push();
      break;
    case 'wait':
      await wait(process.argv[3]);
      break;
    case 'download':
      {
        const runId = process.argv[3];
        if (runId !== undefined && !/^\d+$/.test(runId)) {
          console.error(`Invalid runId "${runId}". Must be a numeric GitHub Actions run ID.`);
          process.exit(1);
        }
        await download(runId || undefined);
      }
      break;
    case 'deploy':
      await deploy();
      break;
    case 'refresh':
      await refresh();
      break;
    case 'serve':
      await serve();
      break;
    case 'list':
      {
        const builds = listVersions();
        if (builds.length === 0) {
          console.log(`No builds in ${BUILDS_DIR}`);
          process.exit(0);
        }
        const h1 = 'runNumber', h2 = 'shortSha', h3 = 'builtAt', h4 = 'sizeHuman', h5 = 'commitMessage';
        console.log(`${h1.padEnd(12)} ${h2.padEnd(10)} ${h3.padEnd(26)} ${h4.padEnd(12)} ${h5}`);
        console.log(`${'─'.repeat(11)} ${'─'.repeat(9)} ${'─'.repeat(25)} ${'─'.repeat(11)} ${'─'.repeat(30)}`);
        for (const b of builds) {
          console.log(
            `${String(b.runNumber).padEnd(12)} ${b.shortSha.padEnd(10)} ${(b.builtAt || '').padEnd(26)} ${b.sizeHuman.padEnd(12)} ${b.commitMessage || ''}`,
          );
        }
      }
      break;
    case 'list-remote':
      {
        const count = process.argv[3] ? parseInt(process.argv[3], 10) : undefined;
        if (count !== undefined && (isNaN(count) || count < 1)) {
          console.error('Count must be a positive integer.');
          process.exit(1);
        }
        await listRemote(count);
      }
      break;
    case 'prune':
      runRetention();
      break;
    default:
      console.error(
        `Usage: node ${process.argv[1]} <push|wait [sha]|download [runId]|deploy|refresh|serve|list|list-remote [count]|prune>`,
      );
      process.exit(1);
  }
} catch (err) {
  console.error(err.message);
  process.exit(1);
}
