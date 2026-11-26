import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';

const workflow = readFileSync(new URL('../../.github/workflows/test.yml', import.meta.url), 'utf8');
const job = workflow.match(/^  nix:\n([\s\S]*?)(?=^  [a-z][\w-]*:\n)/m)?.[1];
assert.ok(job, 'the Nix job must exist');

const check = job.match(/      - name: Build TREK and test its NixOS service\n        run: \|\n((?:          .*\n)+)/)?.[1];
assert.ok(check, 'the Nix job must run the VM check');
const script = check.replace(/^ {10}/gm, '');

function runCheck(present, buildStatus = 0) {
  const dir = mkdtempSync(join(tmpdir(), 'trek-nix-cache-'));
  try {
    const log = join(dir, 'nix.log');
    const fakeNix = join(dir, 'nix');
    writeFileSync(
      fakeNix,
      '#!/bin/sh\nprintf "%s\\n" "$*" >> "$NIX_LOG"\nif [ "$1" = path-info ]; then exit "$NIX_PRESENT"; fi\nexit "$NIX_BUILD_STATUS"\n',
    );
    chmodSync(fakeNix, 0o755);
    const result = spawnSync('sh', ['-e', '-c', script], {
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${dir}:${process.env.PATH}`,
        RUNNER_TEMP: dir,
        NIX_LOG: log,
        NIX_PRESENT: present ? '0' : '1',
        NIX_BUILD_STATUS: String(buildStatus),
      },
    });
    return { status: result.status, calls: readFileSync(log, 'utf8').trim().split('\n') };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe('Nix CI cache', () => {
  it('builds the VM test on a cache miss and rebuilds it on a hit', () => {
    const cold = runCheck(false);
    const warm = runCheck(true);
    assert.equal(cold.status, 0);
    assert.equal(warm.status, 0);
    assert.match(cold.calls[0], /^path-info --offline /);
    assert.match(cold.calls[1], /^build --out-link .* \.#checks\.x86_64-linux\.nixos$/);
    assert.match(warm.calls[1], /^build --rebuild --out-link .* \.#checks\.x86_64-linux\.nixos$/);
  });

  it('fails when either VM build fails', () => {
    assert.equal(runCheck(false, 1).status, 1);
    assert.equal(runCheck(true, 1).status, 1);
  });

  it('keys dependencies and saves only trusted branch pushes', () => {
    assert.match(job, /hashFiles\('flake\.lock', 'package-lock\.json', 'nix\/package\.nix'\)/);
    assert.match(job, /nix build --out-link "\$RUNNER_TEMP\/trek-npm-deps" \.#packages\.x86_64-linux\.trek\.npmDeps/);
    assert.match(job, /nix build --out-link "\$RUNNER_TEMP\/trek-package" \.#trek/);
    assert.match(
      job,
      /if: steps\.nix-cache\.outputs\.hit-primary-key != 'true' && github\.event_name == 'push' && \(github\.ref == 'refs\/heads\/dev' \|\| github\.ref == 'refs\/heads\/main'\)/,
    );
  });
});
