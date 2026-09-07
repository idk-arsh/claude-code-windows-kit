# Claude Code on Windows, one script.
#
# What this does, in order:
# 1. Installs Node LTS, Git, Windows Terminal and VS Code via winget if missing.
# 2. Installs Claude Code globally: `npm install -g @anthropic-ai/claude-code`.
# 3. Verifies `claude --version` works from a fresh shell.
# 4. Prints the next three things you should do (settings, hooks, first run).
#
# Run from an elevated PowerShell if any of the winget steps prompt.
# Rerun any time; every step is idempotent.

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

function Test-WingetInstalled {
    param([string]$Id)
    $result = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
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
    Write-Error "winget not found. Install App Installer from the Microsoft Store, then rerun."
    exit 1
}

Write-Host ""
Write-Host "Step 1 of 3: system packages"
Install-WingetPackage -Id "OpenJS.NodeJS.LTS"        -Label "Node.js LTS"
Install-WingetPackage -Id "Git.Git"                  -Label "Git"
Install-WingetPackage -Id "Microsoft.WindowsTerminal" -Label "Windows Terminal"
Install-WingetPackage -Id "Microsoft.VisualStudioCode" -Label "VS Code"

# Refresh PATH so `node` and `npm` are visible without a new shell.
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" `
          + [Environment]::GetEnvironmentVariable("Path", "User")

Write-Host ""
Write-Host "Step 2 of 3: Claude Code"
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host "  ok   claude on PATH; upgrading"
    npm install -g @anthropic-ai/claude-code 2>&1 | Out-Null
} else {
    Write-Host "  ...  npm install -g @anthropic-ai/claude-code"
    npm install -g @anthropic-ai/claude-code 2>&1 | Out-Null
}
if ($LASTEXITCODE -ne 0) {
    throw "npm install failed. Open a new PowerShell so node is on PATH, then rerun."
}

Write-Host ""
Write-Host "Step 3 of 3: verify"
$claudeVersion = (claude --version) 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "claude --version failed. Open a new terminal and run it by hand."
}
Write-Host "  ok   $claudeVersion"

Write-Host ""
Write-Host "Done. Three things to do next:"
Write-Host ""
Write-Host "  1. Copy settings.example.json to `$HOME\.claude\settings.json and edit."
Write-Host "  2. Wire the hooks in hooks/ by pointing settings.json at their full paths."
Write-Host "  3. Run 'claude' in a project directory."
Write-Host ""
