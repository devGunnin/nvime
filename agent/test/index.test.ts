import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { CLAUDE_VERSION_PROBE_TIMEOUT_MS, DRAIN_TIMEOUT_MS } from '../src/timeouts.js';

/**
 * Only the built sidecar behaves like the real program (`main()` wires real
 * stdin/stdout on import), so this drives it as the child process nvime
 * actually spawns rather than importing it in-process.
 */
const INDEX_TS = fileURLToPath(new URL('../src/index.ts', import.meta.url));

interface Run {
  stdout: string;
  exitCode: number | null;
}

/** Feeds `lines` to the sidecar over stdin and collects everything it prints. */
function runSidecar(lines: string[], env: NodeJS.ProcessEnv, timeoutMs: number): Promise<Run> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', INDEX_TS], {
      env: { ...process.env, ...env },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk: Buffer) => {
      stdout += chunk.toString('utf8');
    });
    child.stderr.on('data', (chunk: Buffer) => {
      stderr += chunk.toString('utf8');
    });
    const watchdog = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`sidecar did not exit within ${timeoutMs}ms; stderr: ${stderr}`));
    }, timeoutMs);
    child.on('exit', (exitCode) => {
      clearTimeout(watchdog);
      resolve({ stdout, exitCode });
    });
    child.on('error', (cause) => {
      clearTimeout(watchdog);
      reject(cause);
    });
    for (const line of lines) child.stdin.write(line + '\n');
    child.stdin.end();
  });
}

describe('index: drain vs. the version probe', () => {
  let dir: string;
  let slowClaude: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'nvime-index-test-'));
    slowClaude = join(dir, 'claude');
    // Slower than the old 5s drain, faster than the 10s probe deadline: the
    // exact gap the merge-gate review reproduced.
    writeFileSync(slowClaude, '#!/bin/sh\nsleep 7\necho "stub 1.0.0"\n');
    chmodSync(slowClaude, 0o755);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it('derives the drain bound above the version probe it must drain', () => {
    // The exact invariant that broke: DRAIN_TIMEOUT_MS (5000) < the probe's own
    // timeout (10000), so a shutdown accepted mid-probe dropped the answer.
    assert.ok(
      DRAIN_TIMEOUT_MS > CLAUDE_VERSION_PROBE_TIMEOUT_MS,
      `DRAIN_TIMEOUT_MS (${DRAIN_TIMEOUT_MS}) must exceed CLAUDE_VERSION_PROBE_TIMEOUT_MS (${CLAUDE_VERSION_PROBE_TIMEOUT_MS})`,
    );
  });

  it('answers a ping accepted just before shutdown, even mid version-probe', async () => {
    const env = { NVIME_CLAUDE_PATH: slowClaude, NVIME_SESSION_STORE: join(dir, 'sessions.json') };
    const lines = ['{"id":1,"method":"ping","params":{}}', '{"id":2,"method":"shutdown","params":{}}'];
    const run = await runSidecar(lines, env, DRAIN_TIMEOUT_MS + 5000);
    assert.match(
      run.stdout,
      /"id":1,"ok":true/,
      `the accepted ping must be answered before exit; got: ${run.stdout}`,
    );
  });
});

describe('index: debug.set mirrors the sidecar into the plugin log', () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'nvime-index-debug-'));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it('takes a level and a path, and records what it handled there', async () => {
    const logPath = join(dir, 'nvime-4242.log');
    const env = { NVIME_SESSION_STORE: join(dir, 'sessions.json') };
    const run = await runSidecar(
      [
        `{"id":1,"method":"debug.set","params":{"level":"info","dir":${JSON.stringify(dir)},"pid":4242}}`,
        '{"id":2,"method":"ping","params":{}}',
        '{"id":3,"method":"shutdown","params":{}}',
      ],
      env,
      DRAIN_TIMEOUT_MS + 5000,
    );
    assert.match(run.stdout, /"id":1,"ok":true/, run.stdout);
    const body = readFileSync(logPath, 'utf8');
    assert.ok(body.includes('ping'), `the sidecar must record what it handled: ${body}`);
  });

  // G5: `requireAbsolutePath` checks only `isAbsolute`, so any path the peer
  // named was written to — `..` segments included. The sidecar builds the path
  // itself now, from a directory and the editor's pid.
  it('builds the path itself and refuses a directory it cannot trust', async () => {
    const cases = [
      `{"id":1,"method":"debug.set","params":{"level":"info","dir":${JSON.stringify(join(dir, 'logs', '..', 'elsewhere'))},"pid":11}}`,
      `{"id":1,"method":"debug.set","params":{"level":"info","dir":"relative/logs","pid":11}}`,
      `{"id":1,"method":"debug.set","params":{"level":"info","dir":${JSON.stringify(dir)},"pid":0}}`,
    ];
    for (const line of cases) {
      const run = await runSidecar([line, '{"id":2,"method":"shutdown","params":{}}'], {}, DRAIN_TIMEOUT_MS + 5000);
      assert.match(run.stdout, /"id":1,"ok":false/, `must be refused: ${line}\n${run.stdout}`);
    }
  });

  it('refuses a level it does not know rather than writing anywhere', async () => {
    const run = await runSidecar(
      [
        `{"id":1,"method":"debug.set","params":{"level":"loud","dir":${JSON.stringify(dir)},"pid":11}}`,
        '{"id":2,"method":"shutdown","params":{}}',
      ],
      { NVIME_SESSION_STORE: join(dir, 'sessions.json') },
      DRAIN_TIMEOUT_MS + 5000,
    );
    assert.match(run.stdout, /"id":1,"ok":false/, run.stdout);
    assert.equal(existsSync(join(dir, 'nvime-11.log')), false);
  });
});
