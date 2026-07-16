#!/usr/bin/env node

// scripts/deploy-ipa.mjs — GitHub deploy pipeline for Ritoras iOS keyboard extension
// Zero-dependency Node.js ES module. Built-in modules only: node:fs, node:path,
// node:child_process, node:os, node:url

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
} from 'node:fs';
import { join } from 'node:path';
import { tmpdir, networkInterfaces } from 'node:os';

const REPO = 'magakis/ritoras';
const BRANCH = 'main';
const ARTIFACT_NAME = 'Ritoras.ipa';
const TOKEN_PATH = '/home/michael/.config/opencode/gh-token';
const DEPLOY_DIR = '/tmp/ritoras-deploy';
const BUNDLE_ID = 'com.ritoras.app';
const REPO_DIR = '/home/michael/IT/ritoras';

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

async function download() {
  mkdirSync(DEPLOY_DIR, { recursive: true });

  // Find the latest successful workflow run
  const data = await ghApi(
    `/repos/${REPO}/actions/runs?per_page=1&status=success`,
  );
  if (data.total_count === 0) {
    throw new Error('No successful workflow runs found');
  }
  const run = data.workflow_runs[0];

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

  const { size } = statSync(ipaPath);
  console.log(`${ARTIFACT_NAME} downloaded to ${ipaPath} (${size} bytes)`);
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
  const ipaPath = join(DEPLOY_DIR, ARTIFACT_NAME);
  if (!existsSync(ipaPath)) {
    console.error("No .ipa found. Run 'download' or 'refresh' first.");
    process.exit(1);
  }

  const { size } = statSync(ipaPath);
  let ipaDownloaded = false;

  const server = createServer((req, res) => {
    const path = req.url;

    if (req.method === 'GET' && path === '/') {
      const host = req.headers.host || detectReachableIPs()[0]?.ip + ':' + port;
      const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Ritoras Install</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 24px;
      background: #f5f5f7;
      color: #1d1d1f;
    }
    @media (prefers-color-scheme: dark) {
      body {
        background: #1c1c1e;
        color: #f5f5f7;
      }
    }
    .container {
      width: 100%;
      max-width: 480px;
      text-align: center;
    }
    h1 {
      font-size: 28px;
      font-weight: 700;
      margin-bottom: 8px;
    }
    .subtitle {
      font-size: 16px;
      color: #6e6e73;
      margin-bottom: 32px;
    }
    @media (prefers-color-scheme: dark) {
      .subtitle {
        color: #98989d;
      }
    }
    .btn {
      display: block;
      width: 100%;
      padding: 14px 20px;
      font-size: 17px;
      font-family: inherit;
      border-radius: 12px;
      text-decoration: none;
      text-align: center;
      -webkit-tap-highlight-color: transparent;
      transition: opacity 0.2s;
    }
    .btn:active {
      opacity: 0.7;
    }
    .btn-primary {
      background: #007aff;
      color: #fff;
      font-weight: 600;
      margin-bottom: 12px;
    }
    .btn-secondary {
      background: transparent;
      color: #007aff;
      border: 1.5px solid #007aff;
      font-weight: 500;
      margin-bottom: 12px;
    }
    @media (prefers-color-scheme: dark) {
      .btn-primary {
        background: #0a84ff;
      }
      .btn-secondary {
        color: #0a84ff;
        border-color: #0a84ff;
      }
    }
    .btn-muted {
      color: #6e6e73;
      border-color: #d2d2d7;
    }
    @media (prefers-color-scheme: dark) {
      .btn-muted {
        color: #98989d;
        border-color: #48484a;
      }
    }
    .note {
      margin-top: 24px;
      font-size: 13px;
      color: #6e6e73;
    }
    @media (prefers-color-scheme: dark) {
      .note {
        color: #98989d;
      }
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>Ritoras</h1>
    <p class="subtitle">Install AltStore-compatible app</p>
    <a class="btn btn-primary" href="sidestore://install?url=http://${host}/Ritoras.ipa">Install via SideStore</a>
    <a class="btn btn-secondary" href="sidestore://">Open SideStore</a>
    <a class="btn btn-secondary btn-muted" href="/Ritoras.ipa">Download .ipa</a>
  </div>
</body>
</html>`;
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(html);
    } else if (req.method === 'GET' && path === '/Ritoras.ipa') {
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Disposition': 'attachment; filename="Ritoras.ipa"',
        'Content-Length': size,
      });
      const stream = createReadStream(ipaPath);
      stream.on('end', () => {
        ipaDownloaded = true;
      });
      stream.on('error', () => {
        res.writeHead(500);
        res.end('Error streaming file');
      });
      stream.pipe(res);
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
  console.log(
    '⏳ Waiting for SideStore to download the .ipa (timeout: 15 minutes)...',
  );

  const start = Date.now();
  const timeout = 15 * 60 * 1000;

  while (Date.now() - start < timeout) {
    if (ipaDownloaded) {
      console.log('✅ IPA downloaded by SideStore. Install in progress...');
      await sleep(10000);
      server.close();
      return;
    }
    await sleep(1000);
  }

  console.log(
    '⚠️ No download detected after 15 minutes. Server is still running — open the URL on your iPhone.',
  );
  server.close();
}

// ---------------------------------------------------------------------------
// CLI Dispatch
// ---------------------------------------------------------------------------

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
      await download();
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
    default:
      console.error(
        `Usage: node ${process.argv[1]} <push|wait [sha]|download|deploy|refresh|serve>`,
      );
      process.exit(1);
  }
} catch (err) {
  console.error(err.message);
  process.exit(1);
}
