import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DEFAULT_FIXTURES_DIRECTORY = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../fixtures/vad-cases',
);

function validateMetadata(metadata, directoryName) {
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) {
    throw new Error(`${directoryName}/meta.json must contain an object`);
  }
  const { case_id: caseId } = metadata;
  if (caseId !== directoryName) {
    throw new Error(`${directoryName}/meta.json case_id must match its directory`);
  }
  if (typeof metadata.session !== 'string' || metadata.session.length === 0) {
    throw new Error(`${directoryName}/meta.json session must be a non-empty string`);
  }
  if (!['failure', 'guard'].includes(metadata.kind)) {
    throw new Error(`${directoryName}/meta.json kind must be failure or guard`);
  }
  if (typeof metadata.mechanism !== 'string' || metadata.mechanism.length === 0) {
    throw new Error(`${directoryName}/meta.json mechanism must be a non-empty string`);
  }
  if (!Number.isInteger(metadata.source_start_sample) || metadata.source_start_sample < 0
    || !Number.isInteger(metadata.source_end_sample)
    || metadata.source_end_sample <= metadata.source_start_sample) {
    throw new Error(
      `${directoryName}/meta.json source sample range must be a non-empty half-open span`,
    );
  }
  if (metadata.sample_rate !== 16_000) {
    throw new Error(`${directoryName}/meta.json sample_rate must be 16000`);
  }
  if (!Array.isArray(metadata.evidence) || !Array.isArray(metadata.limitations)) {
    throw new Error(`${directoryName}/meta.json evidence and limitations must be arrays`);
  }
  if (metadata.warmup !== undefined) validateWarmup(metadata.warmup, directoryName);
  return metadata;
}

// Optional warmup seeds the recorded gate state; prefix_samples feeds rolling history before
// replay starts at the post-emission idle boundary. Fixtures without warmup remain cold-started.
function validateWarmup(warmup, directoryName) {
  if (!warmup || typeof warmup !== 'object' || Array.isArray(warmup)) {
    throw new Error(`${directoryName}/meta.json warmup must be an object`);
  }
  if (!Number.isInteger(warmup.prefix_samples) || warmup.prefix_samples < 0
    || warmup.prefix_samples % 160 !== 0) {
    throw new Error(`${directoryName}/meta.json warmup prefix_samples must be 10 ms aligned`);
  }
  if (!Number.isFinite(warmup.floor_db)
    || typeof warmup.floor_converged !== 'boolean'
    || typeof warmup.priming_complete !== 'boolean'
    || !Number.isFinite(warmup.absolute_speech_floor_db)) {
    throw new Error(`${directoryName}/meta.json warmup gate state is invalid`);
  }
  if (warmup.endpoint_state !== 'idle'
    || warmup.after_emission !== true
    || typeof warmup.within_utterance_context !== 'boolean'
    || warmup.history_source !== 'clip_prefix') {
    throw new Error(`${directoryName}/meta.json warmup replay boundary is unsupported`);
  }
  for (const key of [
    'endpoint_silence_ms',
    'min_speech_ms',
    'min_chunk_ms',
    'analysis_hpf_cutoff_hz',
  ]) {
    if (!Number.isFinite(warmup[key])) {
      throw new Error(`${directoryName}/meta.json warmup ${key} must be finite`);
    }
  }
  if (typeof warmup.analysis_hpf_enabled !== 'boolean') {
    throw new Error(`${directoryName}/meta.json warmup analysis_hpf_enabled must be boolean`);
  }
}

// A missing or empty directory is valid in fresh checkouts without the fixture pack.
export function loadVadFixtures(directory = DEFAULT_FIXTURES_DIRECTORY) {
  if (!fs.existsSync(directory)) return [];
  if (!fs.statSync(directory).isDirectory()) {
    throw new Error(`fixture path is not a directory: ${directory}`);
  }

  return fs.readdirSync(directory, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .sort((left, right) => left.name.localeCompare(right.name))
    .filter(entry => {
      const caseDirectory = path.join(directory, entry.name);
      return fs.existsSync(path.join(caseDirectory, 'meta.json'))
        && fs.existsSync(path.join(caseDirectory, 'clip.wav'));
    })
    .map(entry => {
      const caseDirectory = path.join(directory, entry.name);
      const metadataPath = path.join(caseDirectory, 'meta.json');
      const wavPath = path.join(caseDirectory, 'clip.wav');
      let metadata;
      try {
        metadata = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
      } catch (error) {
        throw new Error(`${entry.name}/meta.json is invalid: ${error.message}`);
      }
      return {
        caseId: entry.name,
        metadata: validateMetadata(metadata, entry.name),
        wavPath,
      };
    });
}
