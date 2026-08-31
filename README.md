# nvime

No vibe coding in my editor. A Claude-native Neovim plugin: Lua is the UI, a
Node sidecar owns every conversation through the
[Claude Agent SDK](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk).

**Subscription auth only.** The SDK drives your local `claude` install and its
existing login. Every variable the shipped SDK reads to supply a credential,
redirect the endpoint, or select another provider or profile —
`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_BASE_URL`,
`ANTHROPIC_CUSTOM_HEADERS`, `ANTHROPIC_PROFILE`, `ANTHROPIC_UNIX_SOCKET`,
`CLAUDE_CODE_USE_*` and the rest — is stripped from the environment the SDK
sees, and `:checkhealth nvime` tells you which of them were set.
`agent/test/env-sdk-contract.test.ts` re-derives the list from the SDK bundle
actually installed in `node_modules`, so a version bump that adds one fails CI
rather than leaking. That derivation classifies by pattern over the bundle's
identifier names, not by reading the bundle's own declared variable sets — a
future SDK release could in principle name a new credential something the
classifier's patterns miss, in which case it would reach the subprocess
unstripped and unwarned.

Proxy and TLS variables (`HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`,
`NODE_EXTRA_CA_CERTS`, `NODE_TLS_REJECT_UNAUTHORIZED`) are deliberately left
alone — they are system-wide conventions, and stripping them would break
corporate networks — but together they can route a prompt and your OAuth
credential through whatever man-in-the-middle you have configured. That is an
accepted tradeoff, not an oversight.

Three capabilities: **Chat** (read-only conversation), **Edit** (you point, it
changes, and you watch it happen) and **Big Change** (claude interrogates the
request into a spec, builds it alone in a disposable clone, and hands you back a
triaged review, then makes you defend it before it merges).

## Requirements

- Neovim >= 0.10
- Node >= 20
- Claude Code installed and signed in (`claude` on `PATH`)

## Install

lazy.nvim:

```lua
{
  'devGunnin/nvime',
  build = 'npm --prefix agent install && npm --prefix agent run build',
  opts = {
    keymaps = { enabled = true },
  },
}
```

`opts` is passed to `require('nvime').setup()`. The build step compiles the
sidecar to `agent/dist/index.js`; the plugin runs that file with `node`.

## Use

| | |
|---|---|
| `:Nvime` | the dashboard: wiring status and every big change in this project |
| `:Nvime chat` | open the chat panel |
| `:Nvime edit` | instruct claude about the current file |
| `:Nvime big` | start or resume a big change |
| `:Nvime diff` | review the changeset |
| `:Nvime cancel` | stop whichever run is going |
| `:checkhealth nvime` | node, claude, sidecar, keymaps |

Keymaps (off until `keymaps.enabled = true`):

| key | where | |
|---|---|---|
| `<leader>nc` | normal | open chat |
| `<leader>ns` | visual | send the selection with its file and line range |
| `<leader>ne` | normal | instruct claude about this file |
| `<leader>ne` | visual | instruct claude about the selection |
| `<leader>nd` | normal | review the changeset |
| `<leader>nB` | normal | open a big change |
| `<CR>` | prompt, normal | send |
| `<C-s>` | prompt, insert | send (so `<CR>` still inserts a newline) |
| `<C-r>` | chat panel | session picker |
| `<C-c>` | panel | stop the running turn |
| `q` | scrollback | close |
| `y` / `n` | approval float | allow once / deny |
| `<CR>` / `r` / `d` | changeset | open the file · revert the hunk · unified diff |
| `<C-t>` | big panel | open the review threads |
| `]t` / `[t` | review | next · previous thread |
| `a` / `r` / `X` | review | defend this thread · request changes · re-open a trivial thread |
| `R` / `M` | review | rebase onto a moved base · merge into your branch |
| `c` `e` `b` `d` / `<CR>` | dashboard | chat · edit · big · changeset / open the change under the cursor |

Every mapping is a leaf: none is a prefix of another, so nothing ever stalls for
`timeoutlen`. `tests/lua/keymaps_spec.lua` enforces it and `:checkhealth` reports it.

**Context.** Write `@path/to/file` or `@path/to/dir` in a prompt and nvime
attaches it — a file as its contents, a directory as a bounded listing. Relative
paths resolve against the project root the panel was opened on, not Neovim's
cwd. Bad, binary or oversized paths are reported in the panel, never silently
dropped. `@` is not confined to the project: `@~/.ssh/id_rsa` is read and sent,
because you asked for it.

**Sessions.** The session for a project root is remembered, so reopening chat
resumes it and replays the earlier turns — the prompts you typed, not the files
they carried. `<C-r>` lists nvime's past sessions for that root by title and
age. Resume survives Neovim restarts, and several Neovim instances share the
session file without overwriting each other.

**Chat is read-only.** It gets `Read`, `Glob`, `Grep`, `WebFetch` and
`WebSearch`; file mutation and shell are denied through SDK options, not prompt
text.

### Edit

`<leader>ne` (or `:Nvime edit`) opens the edit panel scoped to the current file;
from visual mode it scopes to the selection. Type the instruction, `<CR>`. The
prompt stays armed afterwards, so a follow-up continues the same conversation —
and a follow-up is deliberately not pinned to the original file, so "now do the
same for the other queue" works.

**Live application.** Every file the agent changes is pushed to the editor as
its exact before/after the moment the tool finishes. If a buffer holds that
file, only the changed hunks are rewritten through the buffer API: your cursor
and scroll position stay put, the changed lines light up and fade after ~1.5s,
and the buffer is left unmodified and in step with disk — no `:e`, no reload
prompt, and no W11/W12 warning later. "Stay put" means the *line you were on*,
not the line number: a hunk inserted above you moves your cursor down with your
own content. A file nothing has open is simply current when you next open it;
the panel says it changed.

**One undo block per run, per buffer.** A single `u` reverts everything one run
did to that buffer. Honestly: `u` reverts the *buffer*. Disk keeps the agent's
version until you `:w` the reverted buffer.

**Your unsaved work is never clobbered.** If the buffer holds edits the agent
did not see, nvime refuses to touch it and reports a conflict instead. The
change is still on disk and still in the changeset — review and revert it from
`<leader>nd`, or save/discard your edits and re-run.

**Nor is anyone else's write.** Before reconciling a buffer nvime re-reads the
file and requires it to still hold one of the two sides of the change. If a
formatter, a `git checkout`, or a second editor got there in between, nvime
reports `external-change` and writes nothing — the newer content survives, and
the stale mtime is left in place so `:checktime` still warns you.

**Trust is scoped.** Writes under the project root run unattended. A write
anywhere else, and any shell command, stops and asks — a float with `y`/`n`,
never a modal, and the editor stays usable while it waits. An unanswered ask
is denied, as is one whose run you cancelled. The policy lives in the sidecar's
`canUseTool` callback plus a programmatic `PreToolUse` hook, never in prompt
text: the hook is there because the CLI's own safe-command classifier would
otherwise approve some shell calls without asking anyone.

The float shows the **whole** command, or the whole path, wrapped over as many
lines as it takes and scrolled if it does not fit. The one-line summary in the
panel is clipped; the thing you are asked to authorize is not. Past 8 KB the
frame says `!! TRUNCATED` and how many bytes it could not show, so a padded
command is visibly padded rather than quietly ending in an ellipsis.

Paths are resolved one component at a time, the way the kernel resolves them,
so a `..` that follows a symlink out of the project (`node_modules/.pnpm`
links, `docs -> ../shared-docs`, a dotfiles `config -> ~/.config`) climbs out
of the link's target and is asked about — it does not collapse back to a path
that looks like it is inside the root. A symlink whose target does not exist
*yet* is followed the same way, through its link text: a committed
`deploy -> ~/.bashrc.d/x.sh` is a write to your home directory, and the ask
says so. A path that cannot be resolved at all (a symlink loop, a directory
you may not traverse) refuses that one tool call rather than the run.

The ask names where the write really lands whenever that differs from the path
the agent typed, so a `src/vendor/../secret.txt` you would have to decode
through a symlink is shown resolved as well as verbatim.

**A shell step is not silent.** An approved `Bash` call can change files nvime
has no before/after for. When one finishes, nvime reconciles the buffers under
the root with disk: clean ones are brought up to date (and said to be *not* in
the changeset, because they are not), and every other one is named with the
reason rather than touched — unsaved edits, a binary file, or a file the step
deleted out from under a buffer that still holds it.

#### What edit mode does not confine

Read-only tools (`Read`, `Glob`, `Grep`, `WebFetch`, `WebSearch`) are always
allowed and are *not* confined to the project root — edit mode scopes what can
be changed, not what can be read.

Say that plainly, because it is the sharpest edge in the feature: **`Read` any
file you can read, then `WebFetch` an attacker's URL, is a complete
exfiltration path with no approval prompt anywhere in it.** `~/.ssh/id_rsa`, a
`.env`, a password store — none of them are behind the gate, and `WebFetch` is
treated as a read rather than as network egress. The realistic trigger is not
the model deciding to do this; it is prompt-injected content in a repo you
opened, which the model read and followed.

This is a deliberate tradeoff — an agent that cannot read outside the project
cannot follow an import into a dependency — and not one you can currently turn
off. Weigh it before pointing edit mode at an unfamiliar repository. The write
gate is unaffected: nothing here lets the agent *change* anything outside the
root without asking you.

**Changeset.** `<leader>nd` lists every file the run touched with its hunks.
`<CR>` jumps to a hunk, `d` toggles a plain unified diff, and `r` reverts one
hunk through the same live-application path — in either view, on any `+` or `-`
line. A hunk whose lines you have since hand-edited refuses to revert rather
than writing something neither side asked for; a hunk that only moved (because
you reverted something above it) still reverts correctly. Files the agent
created are recorded but not revertible — delete them yourself.

Chat and edit both load **no** `.claude/settings.json` — not the repo's, not yours. Project
settings carry `hooks` (shell commands the model's first `Read` would fire) and
`apiKeyHelper`/`env` (which put back the credentials nvime just stripped), and
none of that is gated by the tool lists. Opening an unfamiliar repo must not be
a decision to trust it, so the guarantee is not made voidable by the code being
read. The cost is that chat does not see the repo's `CLAUDE.md`.

### Big Change

`:Nvime big` (or `<leader>nB`) opens a panel and a conversation, not a form.

**Intake.** Describe the change; claude reads the repo and asks until it is not
guessing, then plays back a spec — goal, scope, approach, acceptance criteria,
and what is deliberately out of scope. The spec comes back as schema-enforced
structured output, so nvime never scrapes it out of prose; if the turn answers
with something unusable, the prose is shown as the next question and **no spec
is invented**, because a fabricated spec is one you would approve without
noticing. Answer, revise, or type `approve`.

**Build.** Approving records the repo's HEAD and returns immediately; the build
then makes a **local clone** of your repository at that commit, HEAD detached,
under `stdpath('data')/nvime/big/<repo>/<session>/wt`. A clone rather than a
worktree: a worktree's `.git` points into *your* repository, and the build runs
shell unattended. `--local` hardlinks the object database, so the clone costs a
checkout and almost no disk, and its `origin` remote is removed — nothing in it
has a path back to your repo. The build agent works there with full mutation
rights, runs whatever tests the project has, and is told not to commit. Progress
streams into the panel; `<C-c>` stops it. Every git call is async, and the
clone happens on the build request, which has no deadline — not on approval,
which would time out on a large repository.

**Triage.** On completion nvime runs `git add -A -N` (so files the build created
are diffable without a commit) and captures `git diff <base>` against the base
commit — which also catches a build that committed anyway. A read-only triage
turn groups the hunks into threads and rates each substantial or trivial. **Every
hunk lands in exactly one thread**: unknown ids are dropped, a hunk claimed twice
goes to its first claimant, and anything triage forgot becomes an open
`unsorted` thread. If the triage turn fails or answers with garbage, it falls
back to one substantial thread per file and says so in the panel — the hunks are
never dropped.

**Threads.** `<C-t>` opens the review in its own tab: the thread list on the
left, that thread's hunks on the right. Trivia auto-resolves but stays in the
list with an `auto` chip and `X` re-opens it, so you always know everything that
changed. `]t`/`[t` walk the list; `<CR>` opens the clone's copy of the file.
`r` sends a comment back to the build agent, which revises the clone in the same
session; the diff is re-captured and re-triaged, and threads whose content is
byte-identical AND rated the same way keep the verdict they had — anything new,
or newly called substantial, comes back open.

**The gate.** `a` on an open substantial thread opens an answer box and asks what
the change does and why. **Paste is blocked**: the put mappings refuse with a
reason, `vim.paste` — what bracketed paste from the terminal calls — is refused
while the box is open, and anything that gets past both, `:put` and a register
put included, is undone by a watcher on the buffer itself, which sees every
change whatever made it. The watcher counts *characters*, not bytes, so a CJK or
IME typist can type an answer at all. Typing is allowed; so is undo and redo of
what you already typed.

It is a paste block, not a sandbox, and this README will not pretend otherwise.
The watcher catches a *burst*, so text fed in slowly enough — `:r`, an external
tool driving the buffer, a paste chopped small — gets through. There is nothing
worth having on the other side of that: the grader grades the answer you submit,
so defeating the block buys a low score and another round.

Submitting runs one read-only grading turn for the round, in the build clone so
the grader can check a claim against the code, resumed across rounds so a
follow-up remembers what it already asked. It grades understanding, not
eloquence: an answer that restates the diff, or that would fit any change of that
shape, scores low; specifics that could only come from reading *this* change
score high. The pass mark is the session's difficulty:

| | |
|---|---|
| `vibe` | no gate — substantial threads arrive cleared |
| `easy` | 40 |
| `medium` | 70 (default) |
| `extreme` | 90 |

Set it in `setup()`, or type `vibe`/`easy`/`medium`/`extreme` in the panel while
the spec is still being drafted. It is fixed at approval: moving the bar
afterwards would re-rate a review that has already happened.

Under the mark the thread stays open and the grader's hint and follow-up render
in it; the next answer has to address the follow-up. There is no round cap and
no override — `X` refuses to clear a substantial thread by hand. If the grading
turn fails or answers unusably, the round is recorded **ungraded**: your answer
is kept, the thread stays open, and the pane says why. A grade nobody gave is
never inferred. Rounds after the first ride the grader's resumed session and
carry only the new answer and its follow-up — the change and the verdicts it
already gave are in that context, and re-sending them every round is what walks
a long review into the context ceiling.

If the triage turn rates **every** thread trivial, nothing is graded, and
`0/0 defended` would be mergeable the moment it was triaged. The diff that turn
read was written by the build agent, so a comment aimed at triage would disarm
the whole gate that way. An all-trivia change therefore gets one more thread,
open: *everything was rated trivial — open the diff and confirm*. Read it
yourself and clear it with `X`. It holds no hunks, so it hides nothing, and it
carries no signature, so every re-capture asks again. No setting removes it —
`vibe` is the one difficulty that runs no gate at all, and that is a choice you
make per change.

**The merge.** `M` lands the reviewed change on the branch the build started
from — the only thing nvime ever writes to your repository. It asserts every
precondition itself rather than trusting the screen, and reports *all* of them at
once: threads still open, a diff that no longer verifies, a binary change (whose
bytes the reviewed diff does not carry), a base branch that moved or went away,
a checkout on some other branch, tracked changes in your tree.

The mechanics are one-way. The commit is built entirely in a private index file
outside the repository — `read-tree` the base, `git apply --cached` (with a
`--3way` fallback), `write-tree`, `commit-tree` — so an interruption at any point
before the end leaves your index, tree and branches byte for byte as they were.
Then the branch `nvime/big/<slug>` is created at that commit with an atomic
create-only `update-ref`, and exactly one command touches your checkout:
`git merge --ff-only`.

`git merge` moves whatever HEAD points at, not the branch you name it, so HEAD
itself is re-read immediately before that command — the ref it is **on** and the
commit it is **at**, both — and again after. A `git checkout -b side` onto a
second branch at the same tip, or a `git checkout --detach`, made between the
precondition check and the merge stops it, rather than fast-forwarding the
reviewed change onto some other ref of yours.

If anything fails, the branch is deleted again and the rollback is *verified*
against the repository **as this attempt found it**: the base is back where it
was, HEAD is on the same ref at the same commit, and the tracked changes are the
ones that were already there. You are told if it could not be. So a tree you had
already edited is not reported as a failed rollback, and a HEAD that moved can
never be certified "exactly as it was". The commit message is the session title,
authored with your own git identity and nothing else.

Once the commit is on your branch nothing can un-land it, so nothing after that
point is reported as a failed merge. If the record write then fails — a full
disk, the store removed under a live run — you are told the change **landed** and
could not be recorded, and the next attempt finds its own commit already on the
branch and says so. Never "your base moved", which would offer to rebase the
build onto your own just-landed change.

The commit is built in a private index in nvime's own store, never inside your
repository, and the lock git writes beside that index is cleared before and
after every merge: a killed `git apply` used to leave one there and wedge every
later merge with git's "another git process seems to be running in this
repository" — about a file in nvime's store, which you have no reason to know
exists.

Afterwards open buffers are refreshed through the same conflict-aware path edit
mode uses: a clean buffer is brought up to date live, one with unsaved edits is
named and left alone. The session is `merged`, which is terminal. The build clone
is kept until you discard it (`big.cleanup_on_merge = true` drops it instead).

If the base branch has moved, `R` rebases the build onto it: the clone fetches
the new base, git moves the work, and a build turn resolves whatever conflicted
and re-runs the tests. A rebase that could not be finished is aborted rather than
left half-applied. The diff is then re-captured and re-triaged — content you
already defended carries forward by signature, and anything the move changed
comes back open.

**State honesty.** Every transition is recorded with its timestamp, and the
record is reconciled against the disk on every read. A build that outlived
Neovim comes back as `building (detached — sidecar gone)` with `resume` and
`discard` as its two exits — never as "built". If the clone is gone the session
drops back to `drafting` with the spec intact; if the captured diff is gone it
drops back to `triaging`, whose exit is `retriage` — the build is done, only the
split is missing, and re-running the build agent over finished work is the wrong
answer. Nothing claims a review is ready without a diff to review.

The captured diff and the threads describing it are written as ONE record, and
each hunk's id is a hash of its own content. So a run that dies between the two
leaves a session with no threads rather than one build's threads rendered over
another build's hunks, and an id held over from an older capture fails to
resolve instead of silently landing on whatever now sits in that slot.

**Two editors, one store.** The store is shared by every Neovim you have open, so
a run claims its session with a heartbeating lock file. A second editor shows
`building (in another editor)` and offers neither `resume` nor `discard`; if the
sidecar holding it dies, the claim goes stale and the session becomes a normal
detached one again.

#### What a big-change build does not confine

Inside its clone the build runs unattended, and that includes `Bash` — a build
has to be able to run your tests. What that does and does not buy you:

* **Confined:** your repository's refs, reflog, config and hooks, and every git
  *command* run inside the clone. The build has its own repository.
  `git update-ref`, `git gc --prune=now`, `git reflog expire`, `git tag -d`,
  `git push` inside the build reach the clone's git and stop there. Nothing
  registers a worktree in your repo, so nothing prunes one either.
* **Confined:** file writes anywhere else. `Edit`/`Write` resolve their path
  through symlinks and are refused outside the clone.
* **NOT confined:** your repository's object database. `--local` *hardlinks*
  it into the clone rather than copying it, so every git command above is
  still safe — git always writes a new object plus a ref update, never in
  place — but a raw write that truncates or overwrites a file under
  `.git/objects` (a stray `chmod` plus `>` from the unconfined shell below,
  say) reaches the same inode your repository reads from, and can corrupt it.
  nvime keeps the hardlink: `--no-hardlinks` would close this, at the cost of
  a full copy of the object database on every single build, which defeats the
  "almost no disk" checkout this feature exists to make cheap. Tools that
  write via tmp-file-plus-rename (`sed -i`, editors, git itself) never hit
  this, because they replace the link rather than the bytes behind it.
* **NOT confined:** shell reaching arbitrary paths. `cd` costs nothing, so the
  boundary is enforcement for file tools and advice for `Bash`. A build that
  wants to read or write elsewhere on your machine can — including, as above,
  your repository's own object database.
* **NOT confined:** the read-only exfiltration edge described for edit mode. It
  applies here too, and without an approval prompt in the way.

Nothing asks. A build is meant to outlive the editor, so a permission prompt
could be raised with nobody there to answer it; the fail-safe answer when no one
is watching is no, and the build is refused immediately and told why. The
review, not a prompt, is where a human looks at the result.

## Configuration

```lua
require('nvime').setup({
  panel = {
    width = 80,          -- columns
    prompt_height = 3,   -- lines
    position = 'right',  -- or 'left'
  },
  keymaps = {
    enabled = false,
    chat = '<leader>nc',
    send_selection = '<leader>ns',
    edit = '<leader>ne',
    changeset = '<leader>nd',
    big = '<leader>nB',
  },
  edit = {
    fade_ms = 1500,              -- how long a fresh hunk stays lit
    nofade = false,              -- keep the highlight until the next change
    approval_timeout_ms = 60000, -- unanswered asks are denied after this
  },
  big = {
    difficulty = 'medium',       -- vibe (no gate) / easy 40 / medium 70 / extreme 90
    cleanup_on_merge = false,    -- drop the build clone once the change lands
  },
  agent = {
    node = 'node',              -- node binary
    claude = nil,               -- absolute path; nil resolves from PATH
    model = nil,                -- nil uses the CLI default
    request_timeout_ms = 15000, -- control requests; a chat turn has no deadline
  },
  context = {
    max_file_bytes = 200 * 1024,
    max_dir_entries = 200,
  },
})
```

## Architecture

```
Neovim (Lua, UI only)  <-- ndjson over stdio -->  nvime-agent (Node)  -->  claude
  panel · markdown                                 sessions · streaming     your login
  keymaps · palette                                permissions
```

One sidecar per Neovim instance, spawned on first use. The wire protocol is
newline-delimited JSON:

```
plugin -> agent   {"id":1,"method":"chat.send","params":{...}}
agent  -> plugin  {"id":1,"ok":true,"result":{"sessionId":"…","usage":{…}}}
agent  -> plugin  {"id":1,"ok":false,"error":{"code":"not_logged_in",…}}
agent  -> plugin  {"event":"chat.delta","params":{"id":1,"text":"…"}}
```

A response terminates its request: `chat.send` answers with the run's completion
payload, so there is one completion path rather than a separate done event.
Events (`chat.started`, `chat.delta`, `chat.tool`) carry no `id` field of their
own — they carry the originating request's id in `params.id`.

Methods: `chat.send`, `chat.list`, `chat.history`, `chat.cancel`,
`edit.start`, `edit.cancel`, `edit.answer`, `edit.list_changes`, `big.create`,
`big.list`, `big.open`, `big.diff`, `big.intake`, `big.approve`, `big.build`,
`big.capture`, `big.revise`, `big.toggle`, `big.answer`, `big.difficulty`,
`big.mergecheck`, `big.merge`, `big.rebase`, `big.discard`, `big.cancel`,
`ping`, `shutdown`.

`big.merge` answers rather than throws when it will not run: `{merged: false,
refusals: [{code, message}]}` is the editor's cue to render every reason at once
and to offer the rebase when `base-moved` is among them.

Edit events: `edit.started`, `edit.delta`, `edit.tool`, `edit.applied` (the
recorded mutation, with before/after snapshots), `edit.approval` and
`edit.approval_settled`. The sidecar owns the change record — the changeset
view re-reads it rather than keeping a second copy that could drift.

Big-change events: `big.started`, `big.delta`, `big.tool`, `big.state`,
`big.denied` (a tool the clone boundary refused) and `big.notice` (triage
fell back). The session record on disk is the source of truth for where a big
change is; the plugin caches none of it, and `big.diff` hands the editor the
captured diff with an index into it rather than every hunk body a second time.

Nothing on the Lua side blocks: no `vim.wait` on agent work, no `vim.fn.input`
or `confirm`, no synchronous process calls. `:checkhealth` is the sole
exception, and every probe there is bounded — it is a diagnostic, never an
editing path.

Colours are derived from your colorscheme at runtime (`Normal`, `Comment`,
`Diff*`, `Diagnostic*`) and re-derived on `ColorScheme`. The only hardcoded
colours are the fallbacks in `lua/nvime/palette.lua`.

## Development

```sh
npm --prefix agent install
npm --prefix agent run build        # -> agent/dist/index.js
npm --prefix agent run typecheck
npm --prefix agent test             # node:test, SDK mocked at the module boundary
nvim --clean -l tests/run.lua       # headless Lua suite
stylua --check lua plugin tests
luacheck lua plugin tests
```

`agent/test/` covers the sidecar (framing, env stripping — including a scan of
the installed SDK bundle — the session store under concurrent writers, the chat
and edit services against a mocked SDK, the root boundary including `..` and
symlink escapes, and the approval gate's deny-by-default exits). `tests/lua/`
covers the plugin (markdown rendering, RPC framing, dispatch and deadlines,
sidecar lifecycle, chat and edit wiring, live buffer application with cursor
preservation, undo grouping and hunk highlights, changeset revert round-trips
and their conflict refusals, the approval float, health reporting, keymap
leaf-only-ness, panel streaming and lifecycle, the picker, config validation,
context expansion, the big-change intake flow and session states, and the review
thread list, chips, hunk slicing and request-changes plumbing, the gate overlay
and its answer box, and the dashboard page).

The paste block is tested by mechanism, not by keystroke: the put mappings, a
register put in insert mode, `vim.paste` (what bracketed paste calls, refused
before the text reaches the buffer at all) and `:put` (undone by the watcher) all
have to be refused, while character-by-character typing, a redo of it, and a CJK
or IME phrase commit get through. The merge tests run against a real scratch repo
and assert the byte-identical rollback — including the case where HEAD moved to a
second branch at the same commit, which is how a merge lands on the wrong ref
while every ref it reads still says what it said at the check. The lock's
compare-and-swap test fails without its fix.

The big-change sidecar tests run against a real scratch git repo: the clone is
really made, the build agent is mocked at the SDK boundary but its writes
are real, and the diff capture and triage fallback run over what it actually
wrote.

## Layout

```
plugin/nvime.lua      :Nvime
lua/nvime/
  init.lua            setup(), dashboard
  config.lua          defaults + validation
  chat.lua            the chat capability
  edit.lua            the edit capability
  apply.lua           live buffer application, undo grouping, hunk highlights
  diffs.lua           pure line diffs and the buffer edits they imply
  changeset.lua       the review view and per-hunk revert
  big.lua             big change: intake, approval, build, session states
  threads.lua         the review threads, the gate overlay, merge and rebase
  dashboard.lua       :Nvime — the front door and this project's big changes
  compose.lua         a float for one piece of free text; paste-blocked for a defense
  approval.lua        the y/n float for a gated tool
  panel.lua           named panels: scrollback + optional prompt
  markdown.lua        pure markdown classifier
  rpc.lua             ndjson client over vim.system
  agent.lua           sidecar lifecycle
  context.lua         @file / @dir / selection
  picker.lua          float list (never a modal)
  palette.lua         colorscheme-derived colours
  keymaps.lua         the keymap table + leaf-only check
  health.lua          :checkhealth nvime
agent/src/
  index.ts            stdio loop, method registration
  rpc.ts              dispatcher
  protocol.ts         frames + line splitting
  chat.ts             the SDK boundary for chat
  edit.ts             the SDK boundary for edit, and the change record
  policy.ts           what edit and big-change builds allow, ask about, deny
  big.ts              the SDK boundary for big change: intake, build, triage, grading
  bigstore.ts         big-change sessions on disk, their lock, and reconciliation
  bigprompts.ts       the big-change prompts and their output schemas
  gate.ts             difficulty thresholds, grade parsing, the defense record
  merge.ts            the local merge: preconditions, landing, verified rollback
  unidiff.ts          unified diff -> files and hunks, with content signatures
  triage.ts           hunks -> review threads, and carrying verdicts forward
  git.ts              every git call big change makes
  approvals.ts        parked asks, denied on timeout or cancel
  snapshot.ts         file before/after, including binary and oversize
  stream.ts           reading the SDK message stream
  sessions.ts         which sessions are nvime's
  context.ts          context blocks -> prompt
  env.ts              subscription-only environment
```
