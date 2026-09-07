# Claude Code on Windows

[![ci](https://github.com/idk-arsh/claude-code-windows-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/idk-arsh/claude-code-windows-kit/actions/workflows/ci.yml)

A setup kit for people running Claude Code on Windows, in plain English. One
install script, a settings file that already knows about Windows paths, and
four hooks that run on stock Windows PowerShell 5.1.

## What is in this repo

| File | What it does |
|---|---|
| [`install.ps1`](install.ps1) | Installs Git, Node LTS, Windows Terminal, VS Code and Claude Code via winget, then merges the settings and copies the hooks into `%USERPROFILE%\.claude\`. Idempotent. `-SettingsOnly` skips the installs. |
| [`settings.example.json`](settings.example.json) | A `settings.json` with Windows-friendly permissions, the `CLAUDE_CODE_GIT_BASH_PATH` variable, and hook wiring for the four hooks in this repo. |
| [`hooks/guard-secrets.ps1`](hooks/guard-secrets.ps1) | PreToolUse on Read, Edit, Write. Blocks paths that look like secrets (`.env`, `id_rsa`, `secrets/`, `*.pem`...) and logs each attempt. |
| [`hooks/guard-git.ps1`](hooks/guard-git.ps1) | PreToolUse on Bash and PowerShell. Blocks force pushes to main or master, `git reset --hard` to a remote ref, `git checkout -- .`, `git clean -f`, `rm -rf` and `Remove-Item -Recurse` on the tree, home or a drive. |
| [`hooks/format-on-edit.ps1`](hooks/format-on-edit.ps1) | PostToolUse on Edit and Write. Runs ruff, black, prettier, gofmt or rustfmt on the file Claude just changed, if the tool exists. Never blocks. |
| [`hooks/notify.ps1`](hooks/notify.ps1) | Stop. Two beeps and a Windows tray notification when Claude finishes a turn. |
| [`tests/`](tests) | Five plain-PowerShell test suites (no Pester) that run every hook the way Claude Code does. `tests\run-all.ps1` runs them all. |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | PSScriptAnalyzer on every `.ps1`, then the suites under both `powershell.exe` and `pwsh` on `windows-latest`. |

Nothing is installed globally except the winget packages. The hooks and
settings live in `%USERPROFILE%\.claude\`, which is where Claude Code already
reads from. If you set `CLAUDE_CONFIG_DIR`, the installer writes there
instead and points the hook commands at that folder.

## Install

```powershell
git clone https://github.com/idk-arsh/claude-code-windows-kit
cd claude-code-windows-kit
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The `-ExecutionPolicy Bypass` part matters: a stock Windows 11 install ships
with the `Restricted` policy, which refuses to run any `.ps1`, including this
one. The flag applies to this one process only and changes nothing on your
machine.

What the script does, in order:

1. `winget install` for Git for Windows, Node.js LTS, Windows Terminal and
   VS Code, skipping anything already present. Git provides Git Bash, which
   Claude Code uses for its Bash tool. Node is there for `npx` MCP servers
   and prettier; Claude Code itself no longer needs it.
2. `winget install Anthropic.ClaudeCode`, unless `claude` is already on PATH
   (native installer, winget or npm), in which case it is left alone. If
   winget is missing, `npm install -g @anthropic-ai/claude-code` is used
   when npm exists; otherwise the script prints the native installer
   command and stops.
3. Settings and hooks, described in the next section.
4. `claude --version`.

Run from an elevated PowerShell if any of the winget steps prompt for admin.
The script is safe to rerun.

To update Claude Code later: `claude update` if you used the native
installer, `winget upgrade Anthropic.ClaudeCode` if winget installed it.
Winget installs do not update themselves.

### Only the settings and hooks

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -SettingsOnly
```

This runs step 3 only: no winget, no install. Use it after a `git pull` of
this repo, or when Claude Code is already installed some other way.

### What step 3 does to your settings.json

- If `%USERPROFILE%\.claude\settings.json` does not exist, the example is
  copied into place. The `env.CLAUDE_CODE_GIT_BASH_PATH` value is replaced
  with the `bash.exe` the script actually finds (next to `git.exe`, or under
  Program Files), and dropped if Git Bash is not installed.
- If it exists, it is backed up to `settings.json.bak-<yyyyMMdd-HHmmss>` and
  merged: `permissions.allow`, `deny` and `ask` become the union of yours and
  the example's, your entries first, no duplicates. Hook entries whose
  command points at one of this kit's four scripts are replaced, wherever
  they sit, including the `%USERPROFILE%\.claude\hooks\...` spelling from
  0.1.0. Every other key (`model`, `theme`, `statusLine`, your own hooks, your
  own `env`) is written back unchanged. The file is written as UTF-8 without a
  BOM. If the file is not valid JSON the script stops and changes nothing.
- The four scripts in `hooks\` are copied to `%USERPROFILE%\.claude\hooks\`.

The merge is exercised by `tests\install.tests.ps1` against throwaway config
directories, so it never touches a real settings file during tests.

## The settings file

The example has four sections worth reading.

- `env.CLAUDE_CODE_GIT_BASH_PATH` tells Claude Code which `bash.exe` to use
  for the Bash tool and for hook commands. Set it when Git is installed
  somewhere other than `C:\Program Files\Git`, or when Claude Code picks up
  WSL's `C:\Windows\System32\bash.exe` instead of Git Bash, which shows up as
  hooks that never run and Bash commands that fail inside a Linux distro. The
  docs' own example value is the one in the file. If the path does not
  exist, Claude Code (2.1.219 and later) ignores the variable, logs a
  warning under `--debug`, and auto-detects Git Bash as usual, so a stale
  value is harmless. The installer fixes or removes it on a fresh copy and
  leaves your `env` alone on a merge.
- `permissions.allow` lets read-only commands run without a prompt: `git
  status`, `git diff`, `npm test`, `pytest`, directory listings.
- `permissions.deny` refuses Read, Edit and Write on files that look like
  secrets (`.env` and its `.local` and per-environment variants, `id_rsa`,
  `~/.ssh/`, `*.pem`, `~/.aws/`, and so on) and refuses `git push` with
  `--force` anywhere in the command, `rm -rf`, and `Remove-Item -Recurse`.
  `.env.example` is left alone on purpose: it is the one dotenv file Claude
  legitimately needs to read and edit.
- `permissions.ask` prompts before `git push`, `git commit`, `npm publish`,
  and any global install.

Two details about the rule syntax, both from the Claude Code docs:

- `Read` deny rules also cover Grep, Glob, Edit, Write and `cat`-style Bash
  commands, so most of the protection comes from the `Read(...)` lines. The
  `Edit(...)` lines are there for older Claude Code versions and NotebookEdit.
  `Write(...)` path rules are accepted but never checked, which is why there
  are none here.
- A bare filename like `Read(.env)` matches at any depth under the current
  directory. A relative directory pattern like `.ssh/**` only matches inside
  the project, so the home-directory files use the `~/` form:
  `Read(~/.ssh/**)`. Absolute paths take `//`, and on Windows a drive is
  spelled `//c/...`.

Bash deny rules are prefix matches on the command text, so they are a
guardrail, not a wall. `rm -rf` is refused; `rm -r -f` is not. That gap is
what `guard-git.ps1` is for.

## The hooks

Claude Code runs hook commands through Git Bash on Windows, or through
PowerShell when Git Bash is missing. The commands in the example are written
so both shells run them:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME/.claude/hooks/guard-git.ps1"
```

`$HOME` rather than `%USERPROFILE%` because both shells expand `$HOME` and
neither expands `%USERPROFILE%`; a literal `%USERPROFILE%` path fails with
exit 127 and the hook silently never runs. Forward slashes because Git Bash
eats backslashes. Every hook reads its JSON payload from stdin as UTF-8
bytes rather than through `[Console]::In`: a process launched without a
console window gets the OEM code page (437 on a US install), and that reader
turns non-ASCII paths, and any leading byte-order mark, into garbage. Each
hook has a `timeout` (10 to 20 seconds); the Claude Code default is 600.

**`guard-secrets.ps1`**, PreToolUse on `Read|Edit|Write`. Checks
`tool_input.file_path` against a regex deny list (`.env`, `id_*`,
`secrets.*` and `secrets/`, `credentials.*`, `*.pem`, `*.key`, anything under
`.ssh/`, `.aws/credentials`, `.git/config`, `.npmrc`, `.pypirc`) and exits 2
with a stderr message when it matches. Exit 2 blocks the call and hands the
message to the model. `.env.example`, `.env.sample` and `.env.template` are
allowed. Every block is logged to `$HOME\.claude\guard-secrets.log`. Bad JSON
or a missing path lets the call through; a failed log write does not. The
`permissions.deny` block catches the same paths without a shell round trip;
what the hook adds is the audit log and regex patterns.

**`guard-git.ps1`**, PreToolUse on `Bash|PowerShell`. Reads
`tool_input.command`, splits it the way a shell would (`&&`, `||`, `;`, `|`,
`&`, newlines, with quotes respected and backslash or backtick line
continuations joined first), tokenises each piece, and blocks:

- `git push` with `--force`, `-f`, `--force-with-lease`, `--force-if-includes`
  or a `+refspec` to `main` or `master`, in any flag order, including
  `HEAD:main` and `refs/heads/main`. With no branch named, the current branch
  is read with `git symbolic-ref` in the payload's `cwd` (or the directory a
  leading `cd` or `git -C` points at); if it is main or master, or cannot be
  read at all, the push is blocked. `--force-with-lease` to a feature branch
  passes. `--all` or `--mirror` with a force flag is blocked. Deleting main
  or master (`--delete`, `-d`, `:main`) is blocked.
- `git reset --hard` with a remote ref (`origin/x`, `@{u}`,
  `refs/remotes/...`, `FETCH_HEAD`). `git reset --hard HEAD~1` is local and
  passes.
- `git checkout -- .` and `git restore .` on the whole tree (`.`, `./`, `:/`,
  `*`). `git restore --staged .` only touches the index and passes.
- `git clean -f` in any spelling unless `-n` or `--dry-run` is present.
- `git branch -D main` or `--delete --force master`.
- `rm` with any recursive flag (`-r`, `-R`, `--recursive`, `-rf`, `-fr`,
  `-r -f`) on `/`, `~`, `$HOME`, `.`, `..`, `*`, `./*`, a drive root (`C:\`,
  `/c`, `/mnt/c`), or with `--no-preserve-root`.
- `Remove-Item` (also `ri`, `del`, `erase`, `rd`, `rmdir`, and cmd's
  `rmdir /s`) with `-Recurse` on the same targets plus `$env:USERPROFILE`.
- The same rules applied to the inner command of `bash -c`, `sh -c`,
  `cmd /c`, `powershell -Command` and `-EncodedCommand`, `pwsh -c`, three
  levels deep.

A block writes a JSON `permissionDecision: "deny"` with the reason to stdout,
the same reason to stderr, and exits 2. The docs prefer the JSON form, and
Claude Code reads it on every exit code; exit 2 is the one signal JSON cannot
override, so the block holds even if the JSON is not parsed. Every block is
logged to `$HOME\.claude\guard-git.log`. Everything else passes, and bad
JSON, a missing command or a parser exception let the call through rather
than wedging the session. This is a guardrail, not a sandbox: `eval`, `$IFS`
tricks and commands stored in variables are not chased.

**`format-on-edit.ps1`**, PostToolUse on `Edit|Write`. Takes
`tool_input.file_path` (Claude Code sends backslash paths on Windows,
absolute or relative to `cwd`), picks a formatter by extension, and runs it
on that one file:

| Extension | Formatter | Where it is looked for |
|---|---|---|
| `.py` | `ruff format`, else `black` | `.venv\Scripts\` or `venv\Scripts\` walking up from the file, then PATH |
| `.js .jsx .ts .tsx .json .css .md` | `prettier --write` | `node_modules\prettier` run through `node`, then `node_modules\.bin\prettier.cmd`, then PATH |
| `.go` | `gofmt -w` | PATH |
| `.rs` | `rustfmt --edition 2021` | PATH |
| `.ps1` | none | skipped; PowerShell has no stock formatter |

No formatter found: nothing happens. Files under `node_modules`, `.venv`,
`venv`, `.git`, `dist`, `build`, `vendor` and `__pycache__` are left alone.
The formatter gets 8 seconds and is killed after that. The hook always exits
0: a PostToolUse hook cannot undo the edit, and a formatter failure is no
reason to interrupt the model. One line per run goes to
`$HOME\.claude\format-on-edit.log`, including skips and their reason, so
"why was my file not formatted" has an answer.

**`notify.ps1`**, Stop. Two short beeps and a Windows tray notification with
the project name in the title. No external modules; the balloon uses
`System.Windows.Forms.NotifyIcon`. Claude Code waits for Stop hooks before it
hands the prompt back, so the balloon runs in a detached hidden PowerShell
and the hook itself returns in about a second.

Test any hook by piping sample JSON at it:

```powershell
'{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' | `
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\hooks\guard-git.ps1
$LASTEXITCODE  # 2 if the deny fired, 0 otherwise
```

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run-all.ps1
powershell -ExecutionPolicy Bypass -File .\tests\lint.ps1   # needs PSScriptAnalyzer
```

Plain PowerShell, no Pester. Each suite launches the hook in a fresh
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File` process with the
payload on stdin, the way Claude Code does, and checks the exit code and
output. `-Shell pwsh` runs everything under PowerShell 7 instead.

- `settings.tests.ps1`: the example parses, every hook command names a script
  that exists and has a timeout, and each command string is run verbatim
  through `bash.exe -c` with `HOME` pointed at a throwaway directory.
- `guard-secrets.tests.ps1`: 39 checks over dotenv variants, keys,
  credentials, rc files, relative and absolute paths, and malformed payloads.
- `guard-git.tests.ps1`: 119 checks including flag order, chains, pipes,
  continuation lines, shell wrappers, and current-branch cases against two
  real throwaway repositories (on `main` and on `feature`).
- `format-on-edit.tests.ps1`: a messy `.py` through ruff (from PATH and from
  a project `.venv`), a `.js` through a project's prettier, files with no
  formatter, and fake formatters that hang or fail. Formatter cases are
  skipped when the tool is not available; CI installs ruff and prettier.
- `install.tests.ps1`: the merge against a scratch config dir: no file,
  a file with extra keys and overlapping entries, a file carrying the 0.1.0
  `%USERPROFILE%` hook commands, and a file that is not JSON.

CI runs `tests\lint.ps1` and `tests\run-all.ps1` on `windows-latest`, the
suites once under `powershell.exe` and once under `pwsh`.

## Windows problems this kit addresses

- **Git Bash versus WSL bash.** Claude Code can resolve `bash` to WSL's
  `C:\Windows\System32\bash.exe` instead of Git Bash, and hook commands then
  fail without a message ([#37634](https://github.com/anthropics/claude-code/issues/37634),
  [#85904](https://github.com/anthropics/claude-code/issues/85904)). The
  example sets `env.CLAUDE_CODE_GIT_BASH_PATH`; the installer fills in the
  real path.
- **CRLF in hook scripts.** A `.sh` hook checked out with CRLF dies with
  `$'\r': command not found` ([#21878](https://github.com/anthropics/claude-code/issues/21878)).
  These hooks are `.ps1` files run by `powershell.exe`, which reads either
  line ending, and `.gitattributes` pins `.ps1`, `.bat` and `.cmd` to CRLF and
  everything else to LF.
- **Execution policy.** A stock Windows client refuses to run `.ps1` files.
  Claude Code passes `-ExecutionPolicy Bypass` itself when it spawns
  PowerShell, the hook commands here do the same, and the README tells you to
  do it for `install.ps1`.
- **`%USERPROFILE%` does not expand in hook commands.** Hooks run through Git
  Bash, which leaves `%USERPROFILE%` as literal text; the hook fails with
  exit 127 and Claude Code treats that as a non-blocking error, so nothing
  tells you. The commands use `$HOME` with forward slashes.
- **stderr under `$ErrorActionPreference = "Stop"`.** Windows PowerShell 5.1
  turns any stderr line from a native command into a terminating error the
  moment that stderr is redirected. npm and winget both write warnings to
  stderr. `install.ps1` never redirects their stderr, and the tests capture
  child output through `System.Diagnostics.Process` instead of `2>&1`.
- **Console code page.** A hook launched without a console window reads
  stdin with the OEM code page. The hooks decode the payload as UTF-8 bytes
  themselves.
- **Hook timeouts.** The default is 600 seconds, so a wedged hook holds a
  turn for ten minutes. Every hook here has a 10 to 20 second timeout, and
  the formatter hook kills its child after 8.

## What this kit does not do

- No Chinese-language docs. The existing kits in that space do the job well.
- No custom slash commands or MCP servers. Those are Claude Code features and
  live outside `%USERPROFILE%\.claude\`; this kit is not a wrapper.
- No opinion on your model choice, prompt style, or agent scaffolding. Ship
  what you like.

## Licence

MIT.
