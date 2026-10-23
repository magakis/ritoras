#!/usr/bin/env node

import fs from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const DEFAULT_CORPUS_PATH = '/home/michael/vad-corpus';
const DEFAULT_LOCAL_PATH = '/tmp/opencode/ritoras-vad-assessment';
const DEFAULT_SOCKET_PATH = '/home/michael/whisper/czechpi.sock';
const REMOTE_ROOT = '/home/michael/whisper/benchmark/recordings';
const REMOTE_BUCKET = 'ritoras';
const SESSION_ID_PATTERN = /^20261023-\d{6}$/;
const EXPECTED_PI_SESSIONS = 40;
const EXPECTED_LOCAL_SESSIONS = 8;
const PHASE3_TRANSCRIPT_FILES = ['chunks.jsonl', 'transcription.txt', 'partial.txt'];

function parseArgs(argv) {
  const options = {
    corpusPath: DEFAULT_CORPUS_PATH,
    localPath: DEFAULT_LOCAL_PATH,
    socketPath: DEFAULT_SOCKET_PATH,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--corpus' || argument === '--local' || argument === '--socket') {
      const value = argv[++index];
      if (!value || value.startsWith('--')) throw new Error(`${argument} requires a path`);
      if (argument === '--corpus') options.corpusPath = path.resolve(value);
      else if (argument === '--local') options.localPath = path.resolve(value);
      else options.socketPath = path.resolve(value);
    } else if (argument === '--help' || argument === '-h') {
      options.help = true;
    } else {
      throw new Error(`unknown option: ${argument}`);
    }
  }
  return options;
}

function remoteCommandForSessionList() {
  const python = [
    'import os,json',
    `root=${JSON.stringify(path.posix.join(REMOTE_ROOT, REMOTE_BUCKET))}`,
    'sessions=sorted(name for name in os.listdir(root) if name.startswith("20261023-") and os.path.isdir(os.path.join(root,name)))',
    'print(json.dumps(sessions))',
  ].join('; ');
  return `python3 -c '${python}'`;
}

function runSsh(socketPath, remoteCommand) {
  const result = spawnSync('ssh', [
    '-S', socketPath,
    '-o', 'BatchMode=yes',
    'czechpi',
    remoteCommand,
  ], { encoding: 'utf8' });
  if (result.error) throw new Error(`could not run ssh: ${result.error.message}`);
  if (result.status !== 0) {
    const detail = result.stderr.trim();
    throw new Error(`SSH read failed${detail ? `: ${detail}` : ''}`);
  }
  return result.stdout;
}

function verifyControlMaster(socketPath) {
  const result = spawnSync('ssh', ['-S', socketPath, '-O', 'check', 'czechpi'], {
    encoding: 'utf8',
  });
  if (result.error) throw new Error(`could not check SSH ControlMaster: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error('SSH ControlMaster socket is not live; no fallback or remote changes were attempted');
  }
}

function extractRemoteSessions(socketPath, ids, stagingPath) {
  const relativePaths = ids.map(id => `${REMOTE_BUCKET}/${id}`);
  const remoteCommand = `tar -C ${REMOTE_ROOT} -cf - -- ${relativePaths.join(' ')}`;
  const ssh = spawn('ssh', [
    '-S', socketPath,
    '-o', 'BatchMode=yes',
    'czechpi',
    remoteCommand,
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
  const tar = spawn('tar', [
    '-xf', '-',
    '-C', stagingPath,
    '--no-same-owner',
    '--no-same-permissions',
  ], { stdio: ['pipe', 'ignore', 'pipe'] });
  let sshError = '';
  let tarError = '';

  ssh.stderr.setEncoding('utf8');
  tar.stderr.setEncoding('utf8');
  ssh.stderr.on('data', chunk => { sshError += chunk; });
  tar.stderr.on('data', chunk => { tarError += chunk; });
  ssh.stdout.pipe(tar.stdin);
  ssh.stdout.on('error', error => { sshError += error.message; });
  tar.stdin.on('error', error => {
    if (error.code !== 'EPIPE') tarError += error.message;
  });

  return Promise.all([
    new Promise((resolve, reject) => {
      ssh.once('error', reject);
      ssh.once('close', (code, signal) => {
        if (code === 0) resolve();
        else reject(new Error(`ssh tar stream failed (${signal ?? code}): ${sshError.trim()}`));
      });
    }),
    new Promise((resolve, reject) => {
      tar.once('error', reject);
      tar.once('close', (code, signal) => {
        if (code === 0) resolve();
        else reject(new Error(`local tar extraction failed (${signal ?? code}): ${tarError.trim()}`));
      });
    }),
  ]);
}

function listSessionIds(directoryPath) {
  if (!fs.existsSync(directoryPath)) throw new Error(`session source does not exist: ${directoryPath}`);
  return fs.readdirSync(directoryPath, { withFileTypes: true })
    .filter(entry => entry.isDirectory() && SESSION_ID_PATTERN.test(entry.name))
    .map(entry => entry.name)
    .sort();
}

function directoryFingerprint(directoryPath) {
  const result = [];
  const visit = (currentPath, relativePath = '') => {
    for (const entry of fs.readdirSync(currentPath, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const childPath = path.join(currentPath, entry.name);
      const childRelativePath = path.posix.join(relativePath, entry.name);
      if (entry.isSymbolicLink()) throw new Error(`session contains a symbolic link: ${childRelativePath}`);
      if (entry.isDirectory()) {
        result.push(`${childRelativePath}/`);
        visit(childPath, childRelativePath);
      } else if (entry.isFile()) {
        const digest = createHash('sha256').update(fs.readFileSync(childPath)).digest('hex');
        result.push(`${childRelativePath}:${digest}`);
      } else {
        throw new Error(`session contains an unsupported file type: ${childRelativePath}`);
      }
    }
  };
  visit(directoryPath);
  return result;
}

function sameSessionContent(leftPath, rightPath) {
  const left = directoryFingerprint(leftPath);
  const right = directoryFingerprint(rightPath);
  return left.length === right.length && left.every((entry, index) => entry === right[index]);
}

function installSession(sourcePath, destinationPath, sessionId, { copy = false } = {}) {
  if (fs.existsSync(destinationPath)) {
    if (!sameSessionContent(sourcePath, destinationPath)) {
      throw new Error(`conflicting local data already exists for ${sessionId}; destination was preserved`);
    }
    return false;
  }
  if (copy) {
    const incomingDirectory = fs.mkdtempSync(
      path.join(path.dirname(destinationPath), `.${sessionId}.incoming-`),
    );
    try {
      const incomingPath = path.join(incomingDirectory, 'session');
      fs.cpSync(sourcePath, incomingPath, { recursive: true, errorOnExist: true, force: false });
      fs.renameSync(incomingPath, destinationPath);
    } finally {
      fs.rmSync(incomingDirectory, { recursive: true, force: true });
    }
  } else {
    fs.renameSync(sourcePath, destinationPath);
  }
  return true;
}

function inventorySession(corpusPath, sessionId, sources) {
  const relativePath = path.posix.join(REMOTE_BUCKET, sessionId);
  const sessionPath = path.join(corpusPath, relativePath);
  const files = fs.readdirSync(sessionPath, { withFileTypes: true })
    .filter(entry => entry.isFile())
    .map(entry => entry.name)
    .sort();
  const missingPhase3Files = PHASE3_TRANSCRIPT_FILES.filter(file => !files.includes(file));
  const telemetryPath = path.join(sessionPath, 'client_telemetry.json');
  let telemetry = { present: fs.existsSync(telemetryPath), frameCount: null };
  if (telemetry.present) {
    try {
      const payload = JSON.parse(fs.readFileSync(telemetryPath, 'utf8'));
      telemetry = {
        present: true,
        frameCount: Array.isArray(payload.frames) ? payload.frames.length : null,
      };
    } catch (error) {
      telemetry = { present: true, frameCount: null, readError: error.message };
    }
  }
  return {
    id: sessionId,
    path: relativePath,
    sources: [...sources].sort(),
    files,
    phase3Artifacts: {
      ready: missingPhase3Files.length === 0,
      missingFiles: missingPhase3Files,
    },
    telemetry,
    status: 'pending-baseline',
    exclusionReason: null,
  };
}

function writeInventory(corpusPath, localPath, remoteIds, localIds, sourceById) {
  const sessions = [...sourceById.keys()]
    .sort()
    .map(id => inventorySession(corpusPath, id, sourceById.get(id)));
  const missingTelemetry = sessions.filter(session => !session.telemetry.present)
    .map(session => ({ id: session.id, reason: 'client_telemetry.json is missing' }));
  const phase3ArtifactWarnings = sessions.filter(session => !session.phase3Artifacts.ready)
    .map(session => ({
      id: session.id,
      missingFiles: session.phase3Artifacts.missingFiles,
      reason: `missing transcript artifact(s): ${session.phase3Artifacts.missingFiles.join(', ')}`,
    }));
  const inventory = {
    generatedAt: new Date().toISOString(),
    date: '2026-10-23',
    corpusPath,
    retentionNote: 'Pi capture storage prunes old sessions; this snapshot was fetched promptly using the read-only SSH ControlMaster and tar-to-stdout.',
    sources: {
      pi: {
        bucket: `${REMOTE_ROOT}/${REMOTE_BUCKET}`,
        sessionCount: remoteIds.length,
        sessionIds: remoteIds,
        transfer: 'SSH ControlMaster socket; tar streamed to local extraction; no Pi-side writes',
        includesAudio: true,
      },
      localMorning: {
        path: localPath,
        sessionCount: localIds.length,
        sessionIds: localIds,
      },
    },
    sessions,
    totals: {
      sessionCount: sessions.length,
      piSessionCount: remoteIds.length,
      localMorningSessionCount: localIds.length,
      telemetryMissing: missingTelemetry,
      telemetryRetentionWarnings: [],
      phase3ArtifactWarnings,
      phase3ArtifactWarningCount: phase3ArtifactWarnings.length,
      fidelityValidated: 0,
      excludedSessionCount: missingTelemetry.length,
      unresolvedDivergenceCount: 0,
      splitSignatureCount: 0,
      liveIncidentCandidateCount: 0,
      healthyControlCount: 0,
    },
  };
  fs.writeFileSync(path.join(corpusPath, 'INVENTORY.json'), `${JSON.stringify(inventory, null, 2)}\n`);
}

export async function syncCorpus({
  corpusPath = DEFAULT_CORPUS_PATH,
  localPath = DEFAULT_LOCAL_PATH,
  socketPath = DEFAULT_SOCKET_PATH,
} = {}) {
  verifyControlMaster(socketPath);
  const remoteIds = JSON.parse(runSsh(socketPath, remoteCommandForSessionList()));
  if (!Array.isArray(remoteIds)
    || remoteIds.some(id => typeof id !== 'string' || !SESSION_ID_PATTERN.test(id))) {
    throw new Error('remote session listing contained an unexpected identifier');
  }
  if (remoteIds.length !== EXPECTED_PI_SESSIONS) {
    throw new Error(`expected ${EXPECTED_PI_SESSIONS} Pi sessions for 2026-10-23; found ${remoteIds.length}`);
  }
  const localIds = listSessionIds(localPath);
  if (localIds.length !== EXPECTED_LOCAL_SESSIONS) {
    throw new Error(`expected ${EXPECTED_LOCAL_SESSIONS} local morning sessions; found ${localIds.length}`);
  }

  fs.mkdirSync(corpusPath, { recursive: true });
  const stagingPath = fs.mkdtempSync(path.join(corpusPath, '.ritoras-import-'));
  const bucketPath = path.join(corpusPath, REMOTE_BUCKET);
  fs.mkdirSync(bucketPath, { recursive: true });
  const sourceById = new Map();
  for (const id of remoteIds) sourceById.set(id, new Set(['pi']));
  for (const id of localIds) {
    if (!sourceById.has(id)) sourceById.set(id, new Set());
    sourceById.get(id).add('local-morning');
  }

  try {
    await extractRemoteSessions(socketPath, remoteIds, stagingPath);
    const stagedBucketPath = path.join(stagingPath, REMOTE_BUCKET);
    const stagedIds = listSessionIds(stagedBucketPath);
    if (stagedIds.length !== remoteIds.length
      || remoteIds.some((id, index) => stagedIds[index] !== id)) {
      throw new Error('tar archive session set differed from the read-only remote inventory');
    }
    for (const id of remoteIds) {
      installSession(
        path.join(stagedBucketPath, id),
        path.join(bucketPath, id),
        id,
      );
    }
    for (const id of localIds) {
      installSession(
        path.join(localPath, id),
        path.join(bucketPath, id),
        id,
        { copy: true },
      );
    }
    writeInventory(corpusPath, localPath, remoteIds, localIds, sourceById);
  } finally {
    fs.rmSync(stagingPath, { recursive: true, force: true });
  }

  return {
    corpusPath,
    piSessionCount: remoteIds.length,
    localMorningSessionCount: localIds.length,
    totalSessionCount: sourceById.size,
  };
}

function usage() {
  return [
    'Usage: node scripts/prediction-sim/bin/corpus-sync.mjs [options]',
    '',
    '  --corpus PATH   Destination corpus root (default /home/michael/vad-corpus)',
    '  --local PATH    Local morning sessions (default /tmp/opencode/ritoras-vad-assessment)',
    '  --socket PATH   SSH mux socket (default /home/michael/whisper/czechpi.sock)',
  ].join('\n');
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  const result = await syncCorpus(options);
  process.stdout.write(`Corpus synchronized: ${result.totalSessionCount} sessions (${result.piSessionCount} Pi, ${result.localMorningSessionCount} local)\n`);
  process.stdout.write(`Inventory: ${path.join(result.corpusPath, 'INVENTORY.json')}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  main().catch(error => {
    process.stderr.write(`${error instanceof Error ? error.message : error}\n`);
    process.exitCode = 1;
  });
}
