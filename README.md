# Claude Code on Windows

A setup kit for people running Claude Code on Windows in plain English. Install
script, a settings file that already knows about Windows paths, and two hooks
you can wire in five minutes.

## What is in this repo

| File | What it does |
|---|---|
| [`install.ps1`](install.ps1) | Installs Node LTS, Git, Windows Terminal, VS Code and Claude Code itself. Idempotent, rerun any time. |
| [`settings.example.json`](settings.example.json) | A `~\.claude\settings.json` with Windows-friendly permissions and hook wiring for the two hooks in this repo. |
| [`hooks/notify.ps1`](hooks/notify.ps1) | Stop hook. System beep and a Windows tray notification when Claude finishes a turn. |
| [`hooks/guard-secrets.ps1`](hooks/guard-secrets.ps1) | PreToolUse hook. Blocks Read, Edit or Write on `.env`, `id_rsa`, `secrets.*` and similar paths, and logs each attempt. |

Nothing installed globally except Claude Code itself and its winget-installed
dependencies. The hooks and settings live in `%USERPROFILE%\.claude\`, which is
the same place Claude Code already reads from.

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

Run from an elevated PowerShell if any of the winget steps prompt for admin.
The script is safe to rerun and skips anything already installed. If `claude`
is already on your PATH from the native installer, winget or npm, the script
leaves it alone; `claude update` upgrades it.

## Set up the settings file

If you have no `settings.json` yet, copy the example into place:

```powershell
New-Item -ItemType Directory -Force $HOME\.claude | Out-Null
if (Test-Path $HOME\.claude\settings.json) {
  "You already have a settings.json. Merge the permissions and hooks blocks by hand."
} else {
  Copy-Item settings.example.json $HOME\.claude\settings.json
}
```

Claude Code writes its own keys to that file (theme, model, update channel),
so if the file exists, do not overwrite it. Open both files and paste the
`permissions` and `hooks` blocks across.

The example has three sections you will want to read:

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

Two details worth knowing about the rule syntax, both from the Claude Code
docs:

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
guardrail, not a wall. `rm -rf` is refused; `rm -r -f` is not.

## Wire the hooks

Copy the two scripts into your `.claude` folder. The `hooks` block in
`settings.example.json` already points at `$HOME/.claude/hooks/`:

```powershell
New-Item -ItemType Directory -Force $HOME\.claude\hooks | Out-Null
Copy-Item hooks\*.ps1 $HOME\.claude\hooks\
```

The hook commands use `$HOME` rather than `%USERPROFILE%` because Claude Code
runs hook commands through Git Bash on Windows (or PowerShell if Git Bash is
missing). Both shells expand `$HOME`; neither expands `%USERPROFILE%`, and a
literal `%USERPROFILE%` path fails with exit 127 and the hook never runs.

**`notify.ps1`** is a Stop hook. It plays two short beeps and pops a Windows
tray notification when Claude finishes a turn, with the current project name
in the title. No external modules; the balloon uses
`System.Windows.Forms.NotifyIcon`, which ships with .NET on Windows. Claude
Code waits for Stop hooks to finish before it gives you the prompt back, so
the balloon runs in a detached hidden PowerShell and the hook itself returns
in about a second.

**`guard-secrets.ps1`** is a PreToolUse hook on Read, Edit and Write. It reads
the tool call on stdin, checks the target path against a regex deny list
(`.env`, `id_*`, `secrets.*` and `secrets/`, `credentials.*`, `*.pem`,
`*.key`, anything under `.ssh/`, `.aws/credentials`, `.git/config`, `.npmrc`,
`.pypirc`), and exits 2 with a stderr message when it matches. Exit 2 blocks
the call and hands the message to the model. `.env.example`, `.env.sample`
and `.env.template` are allowed. Every block is logged to
`$HOME\.claude\guard-secrets.log`. Bad JSON or a missing path lets the call
through; a failed log write does not.

The `permissions.deny` block above catches the same paths without a shell
round trip. What the hook adds is the audit log, and one place for patterns
that are easier to write as regex than as gitignore globs.

Test either hook by piping sample JSON at it:

```powershell
'{"tool_name":"Edit","tool_input":{"file_path":".env"}}' | `
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\hooks\guard-secrets.ps1
$LASTEXITCODE  # 2 if the deny fired, 0 otherwise
```

## Windows things this kit already knows

- **Paths.** `%USERPROFILE%\.claude\` on Windows is what the docs call
  `~/.claude/`. The hook commands use `$HOME` so they resolve under Git Bash
  and PowerShell alike, no matter where your home lives.
- **Line endings.** Scripts are stored LF in git and checked out CRLF on
  Windows by the explicit `*.ps1 text eol=crlf` rule in `.gitattributes`.
  PowerShell runs either; the rule is there so diffs and editors behave.
- **PATH refresh.** `install.ps1` refreshes `$env:Path` after installing Node
  so `npm install -g` works in the same shell.
- **PowerShell 5.1 stderr.** With `$ErrorActionPreference = "Stop"`, 5.1
  turns any stderr line from a native command into a terminating error the
  moment that stderr is redirected. npm and winget both write warnings to
  stderr. `install.ps1` never redirects their stderr for that reason.
- **PowerShell 5.1 versus 7.** Everything here is tested on stock 5.1, which
  ships with Windows. Nothing in it needs 7.

## What this kit does not do

- No Chinese-language docs. The existing kits in that space do the job well.
- No custom slash commands or MCP servers. Those are Claude Code features and
  live outside `%USERPROFILE%\.claude\`; this kit is not a wrapper.
- No opinion on your model choice, prompt style, or agent scaffolding. Ship
  what you like.

## Licence

MIT.
