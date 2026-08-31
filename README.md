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

This is Phase 1: **Chat**. Edit mode (P2) and Big Change with the comprehension
gate (P3/P4) bolt onto the same RPC seam.

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
| `:Nvime cancel` | stop the running turn |
| `:checkhealth nvime` | node, claude, sidecar, keymaps |

Keymaps (off until `keymaps.enabled = true`):

| key | where | |
|---|---|---|
| `<leader>nc` | normal | open chat |
| `<leader>ns` | visual | send the selection with its file and line range |
| `<CR>` | prompt, normal | send |
| `<C-s>` | prompt, insert | send (so `<CR>` still inserts a newline) |
| `<C-r>` | panel | session picker |
| `<C-c>` | panel | stop the running turn |
| `q` | scrollback | close |

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

Chat loads **no** `.claude/settings.json` — not the repo's, not yours. Project
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

P1 methods: `chat.send`, `chat.list`, `chat.history`, `chat.cancel`, `ping`,
`shutdown`. `edit.*` (P2) and `big.*` (P3) register alongside them.

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
the installed SDK bundle — the session store under concurrent writers, and the
chat service against a mocked SDK). `tests/lua/` covers the plugin (markdown
rendering, RPC framing, dispatch and deadlines, sidecar lifecycle, chat wiring,
health reporting, keymap leaf-only-ness, panel streaming and lifecycle, the
picker, config validation, context expansion).

## Layout

```
plugin/nvime.lua      :Nvime
lua/nvime/
  init.lua            setup(), dashboard
  config.lua          defaults + validation
  chat.lua            the chat capability
  panel.lua           scrollback + prompt, streaming render
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
  chat.ts             the SDK boundary
  sessions.ts         which sessions are nvime's
  context.ts          context blocks -> prompt
  env.ts              subscription-only environment
```
