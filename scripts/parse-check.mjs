#!/usr/bin/env node

// scripts/parse-check.mjs — local Swift syntax pre-check via swiftc -parse
// Zero-dependency Node.js ES module. Built-in modules only: node:child_process,
// node:fs, node:os, node:path, node:perf_hooks
//
// Runs swiftc -parse over a set of .swift files, catching Swift syntax errors
// locally in ~3–5 s before pushing to CI. Type errors are uncatchable on Linux
// (no iOS SDK — permanent gap, out of scope). Local-only optimization — not
// wired into CI. The only real build gate remains GitHub Actions.
//
// Modes:
//   node scripts/parse-check.mjs              — parse ALL git-tracked .swift files
//   node scripts/parse-check.mjs --changed    — parse only .swift files modified vs HEAD
//   node scripts/parse-check.mjs <path> [...] — parse only specified .swift files/dirs
//
// Editor integration: SourceKit-LSP (bundled with the toolchain) gives live
// squiggles but spams "No such module 'UIKit'" on every iOS file — this
// script is the cleaner signal.

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function resolveSwiftc() {
  // (a) Process.env.SWIFTC override
  const envPath = process.env.SWIFTC;
  if (envPath && existsSync(envPath)) {
    return envPath;
  }

  // (b) swiftc on PATH
  try {
    return execFileSync('which', ['swiftc'], { encoding: 'utf8' }).trim();
  } catch {
    // not on PATH — continue
  }

  // (c) Swiftly toolchains glob: ~/.local/share/swiftly/toolchains/*/usr/bin/swiftc
  const swiftlyDir = join(homedir(), '.local/share/swiftly/toolchains');
  try {
    const entries = readdirSync(swiftlyDir);
    // Sort descending by version path (e.g. "6.3.3" > "5.10.1") so the
    // highest installed toolchain is chosen.
    entries.sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
    for (const entry of entries) {
      const candidate = join(swiftlyDir, entry, 'usr/bin/swiftc');
      if (existsSync(candidate)) {
        return candidate;
      }
    }
  } catch {
    // swiftly dir missing or unreadable — fall through
  }

  throw new Error(
    'swiftc not found. Install the Swift toolchain via Swiftly:\n' +
    '\n' +
    '  curl -O https://download.swift.org/swiftly/linux/swiftly-x86_64.tar.gz && \\\n' +
    '    tar zxf swiftly-x86_64.tar.gz && ./swiftly init --quiet-shell-followup && \\\n' +
    '    swiftly install latest --use\n',
  );
}

// ---------------------------------------------------------------------------
// File resolution
// ---------------------------------------------------------------------------

function resolveChangedFiles() {
  // --changed mode: parse only .swift files modified vs HEAD. If HEAD doesn't
  // exist (empty repo, first commit), fall back to --cached. If there are no
  // changes at all, fall back to all tracked .swift files (the authoritative
  // set for the pre-commit gate).
  let raw;
  try {
    raw = execFileSync('git', ['diff', '--name-only', '-z', 'HEAD', '--', '*.swift'], { encoding: 'utf8' });
  } catch {
    // HEAD doesn't exist (empty repo / first commit)
    raw = execFileSync('git', ['diff', '--name-only', '-z', '--cached', '--', '*.swift'], { encoding: 'utf8' });
  }
  const files = raw.split('\0').filter(Boolean);
  if (files.length > 0) return files;
  // No changes — fall back to all tracked .swift files
  raw = execFileSync('git', ['ls-files', '-z', '*.swift'], { encoding: 'utf8' });
  return raw.split('\0').filter(Boolean);
}

function resolvePositionalFiles(args) {
  // Expand explicit paths: files ending in .swift are included; directories
  // are walked recursively; non-.swift files are silently skipped; missing
  // paths get a stderr warning but don't abort the run.
  const seen = new Set();
  const result = [];

  for (const arg of args) {
    const absPath = resolve(arg);
    if (!existsSync(absPath)) {
      console.error(`⚠ path not found: ${arg}`);
      continue;
    }

    const stat = statSync(absPath);
    if (stat.isFile()) {
      if (absPath.endsWith('.swift') && !seen.has(absPath)) {
        seen.add(absPath);
        result.push(absPath);
      }
    } else if (stat.isDirectory()) {
      const entries = readdirSync(absPath, { recursive: true });
      for (const entry of entries) {
        const fullPath = join(absPath, entry);
        if (fullPath.endsWith('.swift') && !seen.has(fullPath)) {
          seen.add(fullPath);
          result.push(fullPath);
        }
      }
    }
  }

  return result;
}

function resolveFiles(argv) {
  // If --changed is present, ignore any positional args and use changed mode.
  if (argv.includes('--changed')) {
    return resolveChangedFiles();
  }

  const positional = argv.filter(a => a !== '--changed');
  if (positional.length > 0) {
    return resolvePositionalFiles(positional);
  }

  // Default: all git-tracked .swift files
  const raw = execFileSync('git', ['ls-files', '-z', '*.swift'], { encoding: 'utf8' });
  return raw.split('\0').filter(Boolean);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  // Derive repo root from script location so the script works from any
  // cwd (worktree-safe). Mirrors the deploy-ipa.mjs convention.
  const __filename = fileURLToPath(import.meta.url);
  process.chdir(dirname(dirname(__filename)));

  const swiftc = resolveSwiftc();

  // Parse CLI args and resolve the file set based on the chosen mode
  const argv = process.argv.slice(2);
  const hasChanged = argv.includes('--changed');
  const hasPaths = !hasChanged && argv.some(a => a !== '--changed');
  const files = resolveFiles(argv);

  if (files.length === 0) {
    const msg = hasChanged
      ? 'ℹ no changed Swift files to parse'
      : hasPaths
        ? 'ℹ no Swift files matched the given paths'
        : '⚠  No Swift files found to parse';
    console.log(msg);
    process.exit(0);
  }

  // Batch parse invocation
  const start = performance.now();
  try {
    execFileSync(swiftc, ['-parse', ...files], {
      stdio: ['ignore', 'pipe', 'pipe'],
      encoding: 'utf8',
    });
  } catch (err) {
    const elapsed = ((performance.now() - start) / 1000).toFixed(1);
    console.error(`✗ parse failed after ${elapsed}s:\n`);
    // swiftc diagnostics are editor-parseable file:line:col: error: … lines
    process.stderr.write(err.stderr);

    const errorCount = (err.stderr.match(/: error:/g) || []).length;
    console.error(`\n✗ ${errorCount} diagnostic(s) above`);
    process.exit(1);
  }

  const elapsed = ((performance.now() - start) / 1000).toFixed(1);
  console.log(`✅ ${files.length} Swift file${files.length !== 1 ? 's' : ''} parsed clean in ${elapsed}s`);
  process.exit(0);
} catch (err) {
  console.error('✗', err.message);
  process.exit(1);
}
