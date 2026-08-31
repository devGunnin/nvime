import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
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
