# Claude Code on Windows, one script.
#
# What this does, in order:
# 1. Installs Node LTS, Git, Windows Terminal and VS Code via winget if missing.
# 2. Installs Claude Code globally: `npm install -g @anthropic-ai/claude-code`.
#    If `claude` is already on PATH (native installer, winget or npm), it is
#    left alone; run `claude update` to upgrade.
# 3. Verifies `claude --version` works.
# 4. Prints the next three things you should do (settings, hooks, first run).
#
# Run from an elevated PowerShell if any of the winget steps prompt.
# Rerun any time; every step is idempotent.
#
# Note for anyone editing this: with $ErrorActionPreference = "Stop",
# Windows PowerShell 5.1 turns any stderr output from a native command into
# a terminating error the moment that stderr is redirected (2>&1 or 2>$null).
# npm and winget both write warnings to stderr. Do not redirect their stderr.

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

function Test-WingetInstalled {
    param([string]$Id)
    $result = winget list --id $Id --exact --accept-source-agreements | Out-String
    return $result -match [regex]::Escape($Id)
}

function Install-WingetPackage {
    param([string]$Id, [string]$Label)
    if (Test-WingetInstalled -Id $Id) {
        Write-Host "  ok   $Label already installed"
        return
    }
    Write-Host "  ...  installing $Label"
    winget install --id $Id --exact --silent --accept-source-agreements --accept-package-agreements | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed for $Id (exit $LASTEXITCODE)"
    }
    Write-Host "  ok   $Label installed"
}

Write-Host ""
Write-Host "claude-code-windows-kit installer"
Write-Host "---------------------------------"

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "winget not found. Install App Installer from the Microsoft Store, then rerun."
    exit 1
}

Write-Host ""
Write-Host "Step 1 of 3: system packages"
Install-WingetPackage -Id "OpenJS.NodeJS.LTS"        -Label "Node.js LTS"
Install-WingetPackage -Id "Git.Git"                  -Label "Git"
Install-WingetPackage -Id "Microsoft.WindowsTerminal" -Label "Windows Terminal"
Install-WingetPackage -Id "Microsoft.VisualStudioCode" -Label "VS Code"

# Refresh PATH so `node`, `npm` and `claude` are visible without a new shell.
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" `
          + [Environment]::GetEnvironmentVariable("Path", "User")

Write-Host ""
Write-Host "Step 2 of 3: Claude Code"
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host "  ok   claude already on PATH; leaving it alone (run 'claude update' to upgrade)"
} else {
    Write-Host "  ...  npm install -g @anthropic-ai/claude-code"
    npm install -g @anthropic-ai/claude-code | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "npm install failed. Open a new PowerShell so node is on PATH, then rerun."
    }
}

Write-Host ""
Write-Host "Step 3 of 3: verify"
$claudeVersion = (claude --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "claude --version failed. Open a new terminal and run it by hand."
}
Write-Host "  ok   $claudeVersion"

Write-Host ""
Write-Host "Done. Three things to do next:"
Write-Host ""
Write-Host "  1. Copy settings.example.json to `$HOME\.claude\settings.json if you have"
Write-Host "     no settings file yet. If you do, merge the permissions and hooks"
Write-Host "     blocks into it by hand; do not overwrite it."
Write-Host "  2. Copy hooks\*.ps1 to `$HOME\.claude\hooks\. The example settings"
Write-Host "     already point there."
Write-Host "  3. Run 'claude' in a project directory."
Write-Host ""
