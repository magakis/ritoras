#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runQuietSweep } from './sweep-vad-quiet.mjs';

const ROOT = '/home/michael/whisper/benchmark/vad-telemetry';
const INPUTS = [
  `${ROOT}/20260928/ritoras-vad-telemetry-20260928-110655`,
  `${ROOT}/20260928-pm/ritoras-vad-telemetry-20260928-151639`,
  path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../fixtures/vad-telemetry/EF51BED5-74A4-4D34-A643-D270191219DB-vad.jsonl'),
];
const THETAS = [0.5, 0.6, 0.7];
const cache = { sessions: new Map(), fidelity: new Map() };
const resultsPath = '/tmp/opencode/vad-quiet-sweep-incremental.jsonl';

function stamp() {
  return new Date().toISOString();
}

function evaluate(stage, overrides, index, total) {
  const reports = THETAS.map(theta => runQuietSweep(INPUTS, { overrides, theta, cache }));
  const report = reports[0];
  const soft = report.sessions.filter(item => item.softOnsetCount > 0);
  const row = {
    stage,
    completedAt: stamp(),
    index,
    total,
    overrides,
    hardG1: report.acceptanceGates.G1 === report.sessionCount,
    hardG2: report.acceptanceGates.G2 === report.sessionCount,
    hardG4: report.fidelity.pass,
    fidelity: report.fidelity,
    gatesByTheta: reports.map(item => ({ theta: item.theta, ...item.acceptanceGates })),
    softSessionCount: soft.length,
    softG2QualifiedGrowthSeconds: soft.filter(item => item.gates.G2.pass)
      .reduce((sum, item) => sum + item.gates.G2.qualifiedGrowthSeconds, 0),
    growthSeconds: report.sessions.reduce((sum, item) => sum + item.growthSeconds, 0),
    latchDiscards: report.sessions.reduce((sum, item) => sum + item.latchOriginatedThenDiscardedChurn, 0),
    sessions: report.sessions,
    tele1: report.sessions.find(item => item.id === 'EF51BED5-74A4-4D34-A643-D270191219DB') ?? null,
  };
  fs.appendFileSync(resultsPath, `${JSON.stringify(row)}\n`);
  process.stdout.write(`[${stamp()}] ${stage} ${index}/${total} ${JSON.stringify(overrides)} G1=${row.hardG1} G2=${row.hardG2} G4=${row.hardG4} soft-qualified-growth=${row.softG2QualifiedGrowthSeconds.toFixed(3)}s churn=${row.latchDiscards}\n`);
  return row;
}

function candidateConfigs() {
  return [400, 600, 800].flatMap(quietLatchMs => [0.5, 0.7, 1.0].flatMap(quietLatchDutyCycle => [0, 3, 12].map(quietContinuationRiseCapDbPerSec => ({
    quietLatchMs,
    quietLatchWitnessDb: 3,
    quietLatchWitnessEnabled: true,
    quietLatchDutyCycle,
    quietContinuationRiseCapDbPerSec,
    softOnsetPreRollEnabled: false,
  }))));
}

function rank(left, right) {
  const leftQualified = left.hardG1 && left.hardG2 && left.hardG4;
  const rightQualified = right.hardG1 && right.hardG2 && right.hardG4;
  return Number(rightQualified) - Number(leftQualified)
    || right.softG2QualifiedGrowthSeconds - left.softG2QualifiedGrowthSeconds
    || left.latchDiscards - right.latchDiscards;
}

function main() {
  fs.mkdirSync('/tmp/opencode', { recursive: true });
  fs.writeFileSync(resultsPath, '');
  const started = Date.now();
  const stageAStarted = Date.now();
  const stageA = candidateConfigs().map((config, index, all) => evaluate('A', config, index + 1, all.length));
  const stageASeconds = (Date.now() - stageAStarted) / 1000;
  const baselineWinner = [...stageA].sort(rank)[0];
  const sensitive = new Set(stageA.map(row => `${row.hardG1}:${row.hardG2}:${row.softG2QualifiedGrowthSeconds.toFixed(3)}`)).size > 1;
  const stageA2Started = Date.now();
  const stageA2 = sensitive
    ? [2.5, 4].flatMap(quietLatchWitnessDb => [1.5, 6].map(quietContinuationRiseCapDbPerSec => evaluate('A2', {
      ...baselineWinner.overrides,
      quietLatchMs: 500,
      quietLatchWitnessDb,
      quietContinuationRiseCapDbPerSec,
    }, 1 + ([2.5, 4].indexOf(quietLatchWitnessDb) * 2) + [1.5, 6].indexOf(quietContinuationRiseCapDbPerSec), 4)))
    : [];
  const stageA2Seconds = (Date.now() - stageA2Started) / 1000;
  const winner = [...stageA, ...stageA2].sort(rank)[0];
  const stageBOverrides = [
    ...[500, 750, 1000].map(softOnsetPreRollMs => ({ ...winner.overrides, softOnsetPreRollEnabled: true, softOnsetPreRollMs })),
    ...[false, true].map(quietLatchAmbiguousEnabled => ({ ...winner.overrides, quietLatchAmbiguousEnabled })),
    ...[6, 7.5, 9].map(dynamicsSpreadDb => ({ ...winner.overrides, dynamicsSpreadDb })),
  ];
  const stageBStarted = Date.now();
  const stageB = stageBOverrides.map((config, index, all) => evaluate('B', config, index + 1, all.length));
  const stageBSeconds = (Date.now() - stageBStarted) / 1000;
  const selected = [winner, ...stageB].sort(rank)[0];
  const finalReport = runQuietSweep(INPUTS, { overrides: selected.overrides, theta: 0.6, cache });
  const tele1 = finalReport.sessions.find(item => item.id === 'EF51BED5-74A4-4D34-A643-D270191219DB');
  const tele1Baseline = finalReport.deviceBaseline.find(item => item.id === 'EF51BED5-74A4-4D34-A643-D270191219DB');
  const resultRows = fs.readFileSync(resultsPath, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  const output = {
    completedAt: stamp(),
    elapsedSeconds: (Date.now() - started) / 1000,
    sessionCount: finalReport.sessionCount,
    stageTimings: { A: stageASeconds, A2: stageA2Seconds, B: stageBSeconds, totalSeconds: (Date.now() - started) / 1000 },
    stages: { A: resultRows.filter(row => row.stage === 'A'), A2: resultRows.filter(row => row.stage === 'A2'), B: resultRows.filter(row => row.stage === 'B') },
    topFive: [...resultRows].sort(rank).slice(0, 5),
    chosen: { status: selected.hardG1 && selected.hardG2 && selected.hardG4 ? 'passes hard gates' : 'NO_CONFIG_PASSES_HARD_GATES; best-effort ranked candidate', exactValues: selected.overrides, selectedFrom: selected.stage, hardG1: selected.hardG1, hardG2: selected.hardG2, hardG4: selected.hardG4, softG2QualifiedGrowthSeconds: selected.softG2QualifiedGrowthSeconds, latchDiscards: selected.latchDiscards },
    perSessionGrowth: finalReport.sessions.map(({ id, growthSeconds, growthQualifiedShare, softOnsetCount, latchOriginatedThenDiscardedChurn, gates }) => ({ evaluatedAt: stamp(), id, growthSeconds, growthQualifiedShare, softOnsetCount, latchOriginatedThenDiscardedChurn, gates })),
    thetaDimensions: THETAS.map(theta => ({ theta, ...runQuietSweep(INPUTS, { overrides: selected.overrides, theta, cache }).acceptanceGates })),
    tele1: { session: tele1, candidateChunks: tele1?.candidateEmitIntervals, baselineChunks: tele1Baseline?.emittedIntervals, expectedWindowSeconds: [13.88, 14.5], check: tele1?.candidateEmitIntervals.some(chunk => chunk.s0 / 1000 <= 13.9 && chunk.s1 / 1000 >= 14.5) ?? false },
    rows: resultRows,
  };
  const jsonPath = '/tmp/opencode/vad-quiet-sweep-final.json';
  const mdPath = '/tmp/opencode/vad-quiet-sweep-final.md';
  fs.writeFileSync(jsonPath, `${JSON.stringify(output, null, 2)}\n`);
  const lines = [
    '# Quiet-path VAD sweep',
    '',
    `Completed ${output.completedAt}; elapsed ${output.elapsedSeconds.toFixed(1)} s; sessions ${output.sessionCount}.`,
    `Stage timings: A ${stageASeconds.toFixed(3)} s; A2 ${stageA2Seconds.toFixed(3)} s (${sensitive ? 'ran after Stage A sensitivity' : 'not needed'}); B ${stageBSeconds.toFixed(3)} s.`,
    `Selection status: ${output.chosen.status}.`,
    `Chosen (${output.chosen.selectedFrom}): \`${JSON.stringify(output.chosen.exactValues)}\``,
    `Hard gates G1/G2/G4: ${output.chosen.hardG1}/${output.chosen.hardG2}/${output.chosen.hardG4}; G2-qualified soft-session growth ${output.chosen.softG2QualifiedGrowthSeconds.toFixed(3)} s; latch discards ${output.chosen.latchDiscards}.`,
    '',
    '## Top five',
    '| Rank | Stage | Overrides | G1/G2/G4 | Soft G2 growth (s) | Churn |',
    '| ---: | --- | --- | --- | ---: | ---: |',
    ...output.topFive.map((row, index) => `| ${index + 1} | ${row.stage} | \`${JSON.stringify(row.overrides)}\` | ${row.hardG1}/${row.hardG2}/${row.hardG4} | ${row.softG2QualifiedGrowthSeconds.toFixed(3)} | ${row.latchDiscards} |`),
    '',
    `Stage counts: A ${output.stages.A.length}, A2 ${output.stages.A2.length}, B ${output.stages.B.length}; per-config rows: ${output.rows.length}.`,
    '',
    '## G3 dimensions (reported, not a hard gate)',
    ...output.thetaDimensions.map(item => `- θ=${item.theta}: G3 ${item.G3}/${item.total}; overall ${item.pass}`),
    '',
    `## Tele1: ${tele1Baseline?.emittedIntervals.length ?? 0} device chunks; qualifying chunk covering 13.88–14.5 s: ${output.tele1.check}.`,
    '',
    '## Per-session growth',
    '| Evaluated at | Session | Growth s | Qualified share | Soft onsets | Latch discards | G1 | G2 | G3 |',
    '| --- | --- | ---: | ---: | ---: | ---: | --- | --- | --- |',
    ...output.perSessionGrowth.map(row => `| ${row.evaluatedAt} | ${row.id} | ${row.growthSeconds.toFixed(3)} | ${row.growthQualifiedShare.toFixed(3)} | ${row.softOnsetCount} | ${row.latchOriginatedThenDiscardedChurn} | ${row.gates.G1.pass} | ${row.gates.G2.pass} | ${row.gates.G3.pass} |`),
  ];
  fs.writeFileSync(mdPath, `${lines.join('\n')}\n`);
  process.stdout.write(`[${stamp()}] complete ${jsonPath} ${mdPath}\n`);
}

main();
