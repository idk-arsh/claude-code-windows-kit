# Changelog

## 0.2.0 (2026-09-07)

### Added

- `hooks/guard-git.ps1`: PreToolUse hook on `Bash|PowerShell`. Blocks force
  pushes to main or master (any flag order, `+refspec`, `HEAD:main`, no
  branch named while on main, `--all`/`--mirror`), deleting main or master,
  `git reset --hard` to a remote ref, `git checkout -- .` and `git restore .`
  on the whole tree, `git clean -f` without `-n`, `git branch -D main`, and
  recursive `rm` or `Remove-Item` on `/`, `~`, `.`, `*`, a drive root or with
  `--no-preserve-root`. Handles command chains, quotes, line continuations,
  `cd` and `git -C`, and the inner command of `bash -c`, `cmd /c`,
  `powershell -Command` and `-EncodedCommand`. Writes a JSON deny decision
  and exits 2. Logs to `$HOME\.claude\guard-git.log`.
- `hooks/format-on-edit.ps1`: PostToolUse hook on `Edit|Write`. Runs ruff
  (else black), prettier, gofmt or rustfmt on the edited file when the tool is
  in the project or on PATH. 8 second child timeout, always exits 0, one log
  line per run in `$HOME\.claude\format-on-edit.log`.
- `install.ps1` merges `settings.example.json` into an existing
  `settings.json` instead of telling you to do it by hand: backup to
  `settings.json.bak-<timestamp>`, union of the permission lists with your
  entries first, kit hook entries replaced in place (including the 0.1.0
  `%USERPROFILE%` spelling), every other key untouched, UTF-8 without BOM.
  Honours `CLAUDE_CONFIG_DIR`. Copies the hooks to `<config dir>\hooks\`.
- `install.ps1 -SettingsOnly` runs the settings and hooks step alone.
- `install.ps1` installs Claude Code with `winget install Anthropic.ClaudeCode`.
  npm is the fallback only when winget is missing.
- `env.CLAUDE_CODE_GIT_BASH_PATH` in `settings.example.json`. The installer
  replaces it with the detected `bash.exe` or drops it when Git Bash is
  absent.
- `tests/`: five plain-PowerShell suites, 269 checks at this release
  (settings 24, guard-secrets 39, guard-git 119, format-on-edit 45, install
  42), plus `run-all.ps1` and `lint.ps1`.
- `.github/workflows/ci.yml`: PSScriptAnalyzer with the ruleset in
  `PSScriptAnalyzerSettings.psd1`, then the suites under `powershell.exe` and
  `pwsh` on `windows-latest`.

### Changed

- All hooks read stdin as UTF-8 bytes instead of `[Console]::In`, which uses
  the OEM code page when the hook runs without a console window.
- README rewritten around the four hooks, the merge, the tests and a list of
  the Windows problems the kit addresses.

### Fixed

- Hook commands used `%USERPROFILE%`, which Git Bash does not expand, so the
  hooks never ran (exit 127, reported as a non-blocking error). Commands now
  use `$HOME` with forward slashes.
- `install.ps1` redirected stderr from npm and winget under
  `$ErrorActionPreference = "Stop"`, which turns their warnings into
  terminating errors on Windows PowerShell 5.1. It also reinstalled Claude
  Code over an existing native install, and printed an exception dump when
  winget was missing.
- `settings.example.json` carried `Write(...)` path rules, which Claude Code
  accepts but never checks; relative `.ssh/**` and `.aws/credentials` rules
  that never matched the home directory; `Bash(...)` rules for PowerShell
  cmdlets; and a `git push --force` rule that only matched one flag order.
  `.env.example` was blocked.
- `guard-secrets.ps1` matcher was `Edit|Write`; Read is now covered. Five
  patterns required a leading separator and missed relative paths;
  `secrets/` folders were missed; the audit log write ran outside try/catch
  and a locked log file turned a block into an allow.
- `notify.ps1` slept 3.2 seconds in the foreground and stalled every turn;
  the balloon now runs in a detached process.
- `.ps1` files are stored CRLF in the working tree as `.gitattributes`
  says; the README claimed the `text=auto` default did this.

## 0.1.0 (2026-09-07)

- `install.ps1`: winget installs of Node LTS, Git, Windows Terminal and VS
  Code, then `npm install -g @anthropic-ai/claude-code`.
- `settings.example.json`: permissions allow, deny and ask lists tuned for a
  Windows machine, with hook wiring for the two hooks.
- `hooks/guard-secrets.ps1`: PreToolUse hook blocking secret-looking paths.
- `hooks/notify.ps1`: Stop hook with a beep and a tray notification.
