import { execFileSync } from 'node:child_process';

/**
 * Local identity for a scratch test repo. CI runners carry no global
 * user.name/user.email — unlike a dev machine, which masks it — so every
 * fixture that inits a repo must set one itself or `git commit`/`git rebase`
 * refuse to write a commit. `commit.gpgsign=false` guards the same runners
 * against an operator gitconfig that signs by default.
 */
export function configureGitIdentity(dir: string): void {
  const run = (...args: string[]): void => {
    execFileSync('git', args, { cwd: dir, stdio: 'pipe' });
  };
  run('config', 'user.email', 'nvime@example.invalid');
  run('config', 'user.name', 'nvime tests');
  run('config', 'commit.gpgsign', 'false');
}
