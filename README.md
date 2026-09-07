# Claude Code on Windows

A setup kit for people running Claude Code on Windows in plain English. Install
script, a settings file that already knows about Windows paths, and two hooks
you can wire in five minutes.

## What is in this repo

| File | What it does |
|---|---|
| [`install.ps1`](install.ps1) | Installs Node LTS, Git, Windows Terminal, VS Code and Claude Code itself. Idempotent, rerun any time. |
| [`settings.example.json`](settings.example.json) | Drop-in `~\.claude\settings.json` with Windows-friendly permissions and hook wiring for the two hooks in this repo. |
| [`hooks/notify.ps1`](hooks/notify.ps1) | Stop hook. System beep and a Windows toast when Claude finishes a turn. |
| [`hooks/guard-secrets.ps1`](hooks/guard-secrets.ps1) | PreToolUse hook. Blocks Edit or Write to `.env`, `id_rsa`, `secrets.*` and similar paths. |

Nothing installed globally except Claude Code itself and its winget-installed
dependencies. The hooks and settings live in `%USERPROFILE%\.claude\`, which is
the same place Claude Code already reads from.

## Install, in one line

```powershell
git clone https://github.com/idk-arsh/claude-code-windows-kit
cd claude-code-windows-kit
./install.ps1
```

Run from an elevated PowerShell if any of the winget steps prompt for admin.
The script is safe to rerun and will skip anything already installed.

## Set up the settings file

Copy the example to your home directory:

```powershell
Copy-Item settings.example.json $HOME\.claude\settings.json
```

The file has three sections you will want to read:

- `permissions.allow` lets read-only commands run without a prompt: `git
  status`, `git diff`, `npm test`, `pytest`, directory listings.
- `permissions.deny` refuses Edit and Write on files that look like secrets
  (`.env`, `id_rsa`, `.ssh\`, `*.pem`, `.aws\credentials`, and so on) and
  refuses `git push --force` and `rm -rf`.
- `permissions.ask` prompts before `git push`, `git commit`, `npm publish`,
  and any global install.

Add or remove entries to taste. The pattern language is standard gitignore
syntax; `*` matches within a path segment, `**` across segments.

## Wire the hooks

Copy the two scripts into your `.claude` folder and the `hooks` block in
`settings.example.json` already points at the right paths:

```powershell
New-Item -ItemType Directory -Force $HOME\.claude\hooks | Out-Null
Copy-Item hooks\*.ps1 $HOME\.claude\hooks\
```

**`notify.ps1`** is a Stop hook. It plays two short beeps and pops a Windows
tray notification when Claude finishes a turn, with the current project name
in the title. No external modules; the balloon uses
`System.Windows.Forms.NotifyIcon`, which ships with .NET on Windows.

**`guard-secrets.ps1`** is a PreToolUse hook on Edit and Write. It reads the
tool call on stdin, checks the target path against a deny list (`.env`,
`id_*`, `secrets.*`, `credentials.*`, `*.pem`, `*.key`, anything under `.ssh\`
or `.aws\credentials`), and exits 2 with a stderr message when it matches.
Every block is logged to `$HOME\.claude\guard-secrets.log`.

The `permissions.deny` block above catches the same simple cases without a
shell round trip. The hook adds two things `permissions` cannot: it catches
absolute paths (deny patterns are relative to the project), and it writes an
audit line for every attempt.

Test either hook by piping sample JSON at it:

```powershell
'{"tool_name":"Edit","tool_input":{"file_path":".env"}}' | `
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\hooks\guard-secrets.ps1
$LASTEXITCODE  # 2 if the deny fired, 0 otherwise
```

## Windows things this kit already knows

- **Paths.** `%USERPROFILE%\.claude\` on Windows, not `~/.claude/`. The
  install script and every hook use the environment variable so it works no
  matter where your home lives.
- **Line endings.** Every script in this repo is authored LF; Git converts to
  CRLF on checkout on Windows via the `.gitattributes` `text=auto` default,
  which is what PowerShell expects.
- **PATH refresh.** `install.ps1` refreshes `$env:Path` after installing Node
  so `npm install -g` works in the same shell.
- **PowerShell 5.1 versus 7.** Everything here runs on stock 5.1 (which ships
  with Windows) and 7 (which winget installs on request).

## What this kit does not do

- No Chinese-language docs. The existing kits in that space do the job well.
- No custom slash commands or MCP servers. Those are Claude Code features and
  live outside `%USERPROFILE%\.claude\`; this kit is not a wrapper.
- No opinion on your model choice, prompt style, or agent scaffolding. Ship
  what you like.

## Licence

MIT.
