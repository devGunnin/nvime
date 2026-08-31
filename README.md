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

Two capabilities so far: **Chat** (read-only conversation) and **Edit** (you
point, it changes, and you watch it happen). Big Change with the comprehension
gate (P3/P4) bolts onto the same RPC seam.

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
| `:Nvime` | capabilities and wiring status |
| `:Nvime chat` | open the chat panel |
| `:Nvime edit` | instruct claude about the current file |
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
| `<CR>` | prompt, normal | send |
| `<C-s>` | prompt, insert | send (so `<CR>` still inserts a newline) |
| `<C-r>` | chat panel | session picker |
| `<C-c>` | panel | stop the running turn |
| `q` | scrollback | close |
| `y` / `n` | approval float | allow once / deny |
| `<CR>` / `r` / `d` | changeset | open the file · revert the hunk · unified diff |

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
text. Editing arrives in P2 behind its own gate.

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
  },
  edit = {
    fade_ms = 1500,              -- how long a fresh hunk stays lit
    nofade = false,              -- keep the highlight until the next change
    approval_timeout_ms = 60000, -- unanswered asks are denied after this
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
`edit.start`, `edit.cancel`, `edit.answer`, `edit.list_changes`, `ping`,
`shutdown`. `big.*` (P3) registers alongside them.

Edit events: `edit.started`, `edit.delta`, `edit.tool`, `edit.applied` (the
recorded mutation, with before/after snapshots), `edit.approval` and
`edit.approval_settled`. The sidecar owns the change record — the changeset
view re-reads it rather than keeping a second copy that could drift.

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
context expansion).

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
  policy.ts           what edit mode allows, asks about, and denies
  approvals.ts        parked asks, denied on timeout or cancel
  snapshot.ts         file before/after, including binary and oversize
  stream.ts           reading the SDK message stream
  sessions.ts         which sessions are nvime's
  context.ts          context blocks -> prompt
  env.ts              subscription-only environment
```
