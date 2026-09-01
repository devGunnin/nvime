# Changelog

## Unreleased

- **Per-mode model + reasoning-effort dial.** A new `models` config table
  (`chat`, `edit`, `big_build`, `big_intake`, `big_grade`, `explain`) sets the
  model and effort each lane's agent turns run at; nil keeps the CLI default.
  `:Nvime model` layers a session-scoped override on top, visible in `:Nvime
  doctor` and appended to `statusline()`. The grader lane refuses effort
  `low` — grading is the comprehension gate itself. Replaces the old, single
  global `agent.model` setting.

## 2.0.0

A ground-up rewrite. v1's 32k lines of Lua, 30 commands, 8 internal lanes and
two hand-written stream parsers are gone; nothing is carried over but the
ideas.

### The shape

- **Three capabilities, eight commands.** Chat, Edit and Big Change behind one
  `:Nvime` entry point and a single `<leader>n` namespace. Plans, perf, critic,
  recap, the MCP server, the PR sidecar, the attribution ledger and the usage
  dashboard are all cut.
- **Claude only.** The provider abstraction is deleted rather than generalised,
  along with the Codex backend and the ~400 lines of per-provider glue that
  leaked into six other files.
- **A real agent runtime.** A Node sidecar built on the Claude Agent SDK owns
  every conversation; Lua is a pure UI layer talking to it over ndjson on
  stdio. No argv is assembled by hand, no stream is parsed with pattern
  matching, and no structured answer is scraped out of prose — grading and
  triage come back schema-enforced.
- **Subscription auth only.** The SDK drives your local `claude` install and
  its existing login. Every credential, endpoint and provider-selection
  variable is stripped from the environment the SDK sees, and a test re-derives
  that list from the SDK bundle actually installed, so a version bump that adds
  one fails CI rather than leaking.
- **Nothing blocks.** No `vim.wait` on agent work, no `vim.fn.input` or
  `confirm`, no synchronous repo copies. Every prompt is a float with keybinds.
  `:checkhealth` is the one deliberate exception.

### Chat

- Streaming markdown with fenced code highlighted by the real grammar for its
  language; tool calls interjected as they happen.
- `@file` / `@dir` context, resolved against the panel's project root and
  gitignore-aware in completion; visual selections sent with their line range.
- Sessions resume by project root and survive editor restarts; `<C-r>` picks a
  past one. Several editors share the session file without clobbering it.
- Read-only by construction: mutation and shell are denied through SDK options.

### Edit

- Live buffer application: the changed hunks are rewritten through the buffer
  API the moment a tool finishes, cursor and scroll preserved, no `:e` and no
  W11/W12 later.
- One undo block per run, per buffer.
- A buffer with unsaved edits is refused rather than overwritten; a file some
  other writer touched in between is reported and left alone.
- Writes under the project root run unattended; anything else, and every shell
  command, opens a `y`/`n` float carrying the whole payload verbatim. Paths are
  resolved a component at a time, so a `..` through a symlink cannot collapse
  back inside the root.
- A changeset view with per-hunk revert through the same live-application path.

### Big Change

- Intake that interrogates the request into a spec and plays it back; nothing
  is invented when the turn answers unusably.
- Builds in a disposable local clone with `origin` removed, not a worktree.
- Diff capture and agent triage into review threads; every hunk lands in
  exactly one, and a failed triage falls back rather than dropping hunks.
- The comprehension gate: a typed, paste-blocked defense per substantial
  thread, graded against the session's difficulty, with hints and Socratic
  follow-ups and no override.
- A local merge that asserts every precondition, builds its commit in a private
  index outside your repository, touches your checkout with exactly one
  `git merge --ff-only`, and verifies its own rollback.
- `R` rebases onto a moved base and re-reviews, carrying cleared threads
  forward by content signature.
- Session state is reconciled against disk on every read; a build that outlived
  the editor comes back as detached, never as "built".

### Looks

- Colours derive from the active colorscheme and re-derive on `ColorScheme`.
  Only foregrounds are read: every background nvime paints is that foreground
  blended into your own `Normal` background, so an added hunk reads green even
  under a colorscheme whose `DiffAdd` background is neutral grey, and the same
  palette works on a light background.
- Panels have real chrome: a titled bar with the keys right-aligned, a left
  gutter, wrapped lines that keep their indent, and code blocks with one
  continuous background rather than a ragged per-line one.
- The review reads as a review: chips are badges, `+`/`-` lines get tinted
  bands, and the gate names the speaker once per answer with the score coloured
  by whether it cleared the thread.
- `ui.icons` picks between a plain-Unicode glyph set (no private-use Nerd Font
  codepoints) and pure ASCII.
- Every surface is screenshot-verified against a real terminal, in both a
  light and a dark background except the approval float (dark only) and the
  transparent-background case (light only); the set is committed under
  `assets/`.

### Fixed

- `[]]` in a `.gitignore` — git's own spelling for a literal `]` — compiled to
  an empty Lua character class. The failure surfaced at match time rather than
  at load, so the load-time probe accepted the rule and the first path it was
  tested against aborted the whole `@`-completion walk.
- A panel stopped following its stream for the rest of a run the first time one
  delta committed more than two lines at once.
- The approval float was sized in buffer lines while the window wrapped, so a
  two-line summary could push the command being consented to off the bottom.
- A tool status line for a file outside the project read as a ladder of `..`
  segments instead of saying where the file is.
