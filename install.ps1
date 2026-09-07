# Claude Code on Windows, one script.
#
# What this does, in order:
# 1. Installs Git for Windows, Node LTS, Windows Terminal and VS Code via
#    winget if missing. Git provides Git Bash, which Claude Code needs for
#    its Bash tool. Node is for npx-based MCP servers and prettier; Claude
#    Code itself no longer needs it.
# 2. Installs Claude Code with `winget install Anthropic.ClaudeCode`. If
#    `claude` is already on PATH (native installer, winget or npm) it is left
#    alone. If winget is missing, falls back to `npm install -g
#    @anthropic-ai/claude-code` when npm exists, and otherwise prints the
#    native installer command.
# 3. Writes the settings and hooks. If <config dir>\settings.json does not
#    exist, copies settings.example.json into place. If it does, backs it up
#    to settings.json.bak-<timestamp> and merges: the permissions.allow, deny
#    and ask lists are unioned (your entries first, no duplicates), hook
#    entries that point at this kit's scripts are replaced, every other key
#    (model, theme, statusLine, your own hooks...) is left as it was. The
#    hook scripts are copied to <config dir>\hooks\. The config dir is
#    %USERPROFILE%\.claude, or CLAUDE_CONFIG_DIR when that is set, which is
#    where Claude Code reads its user settings.
# 4. Verifies `claude --version` works.
#
# -SettingsOnly runs step 3 only: no winget, no install, just the settings
# merge and the hook copy. Use it after a git pull of this repo.
#
# Run from an elevated PowerShell if any of the winget steps prompt.
# Rerun any time; every step is idempotent.
#
# Note for anyone editing this: with $ErrorActionPreference = "Stop",
# Windows PowerShell 5.1 turns any stderr output from a native command into
# a terminating error the moment that stderr is redirected (2>&1 or 2>$null).
# npm and winget both write warnings to stderr. Do not redirect their stderr.

[CmdletBinding()]
param(
    [switch]$SettingsOnly
)

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$KitRoot = $PSScriptRoot
$KitHookNames = @('guard-secrets', 'guard-git', 'format-on-edit', 'notify')

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

function Sync-SessionPath {
    # Refresh PATH so tools installed a moment ago are visible in this shell.
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" `
              + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Get-ClaudeConfigDir {
    # Claude Code resolves ~ through USERPROFILE on Windows, and honours
    # CLAUDE_CONFIG_DIR when it is set. Match that, not PowerShell's $HOME.
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    return (Join-Path $homeDir ".claude")
}

function Get-GitBashPath {
    # Where Git Bash is, if anywhere. Same search Claude Code documents: the
    # CLAUDE_CODE_GIT_BASH_PATH variable, then next to git.exe, then the
    # usual install roots.
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:CLAUDE_CODE_GIT_BASH_PATH) { $candidates.Add($env:CLAUDE_CODE_GIT_BASH_PATH) }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
        $candidates.Add((Join-Path $gitRoot "bin\bash.exe"))
    }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, (Join-Path $env:LOCALAPPDATA "Programs"))) {
        if ($root) { $candidates.Add((Join-Path $root "Git\bin\bash.exe")) }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Test-HasProperty {
    param($Object, [string]$Name)
    return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name])
}

function Add-ObjectProperty {
    # Adds or replaces a property on a PSCustomObject from ConvertFrom-Json.
    param($Object, [string]$Name, $Value)
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Merge-StringList {
    # Existing entries first, in their order, then incoming entries that are
    # not already present. Exact string comparison, duplicates dropped.
    param([object[]]$Existing, [object[]]$Incoming)
    $merged = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Existing) + @($Incoming)) {
        if ($null -ne $item -and -not $merged.Contains($item)) { $merged.Add($item) }
    }
    return , [object[]]$merged.ToArray()
}

function Test-KitHook {
    # True when a hook entry runs one of this kit's scripts, in any spelling:
    # $HOME/.claude/hooks/x.ps1, %USERPROFILE%\.claude\hooks\x.ps1, or the
    # hooks folder of a custom CLAUDE_CONFIG_DIR.
    param($Hook, [string]$Pattern)
    if ($null -eq $Hook) { return $false }
    $text = ''
    if (Test-HasProperty $Hook 'command') { $text = [string]$Hook.command }
    if (Test-HasProperty $Hook 'args') { $text += ' ' + (@($Hook.args) -join ' ') }
    return ($text -match $Pattern)
}

function Convert-KitHookPath {
    # The example points at $HOME/.claude/hooks/. With a custom config dir
    # the hooks live somewhere else, so point the commands there instead.
    param($Settings, [string]$HooksDirForward)
    if (-not (Test-HasProperty $Settings 'hooks')) { return }
    foreach ($eventProp in @($Settings.hooks.PSObject.Properties)) {
        foreach ($group in @($eventProp.Value)) {
            if (-not (Test-HasProperty $group 'hooks')) { continue }
            foreach ($hook in @($group.hooks)) {
                if (Test-HasProperty $hook 'command') {
                    $hook.command = $hook.command -replace [regex]::Escape('$HOME/.claude/hooks/'), ($HooksDirForward + '/')
                }
            }
        }
    }
}

function Merge-Configuration {
    # Merges the example into the user's settings object, in place. Returns
    # counts for the summary line.
    param($Existing, $Example, [string]$KitHookPattern)
    $summary = [ordered]@{ allow = 0; deny = 0; ask = 0; HooksRemoved = 0; HooksAdded = 0 }

    if (-not (Test-HasProperty $Existing 'permissions') -or $null -eq $Existing.permissions) {
        Add-ObjectProperty -Object $Existing -Name 'permissions' -Value ([pscustomobject]@{})
    }
    foreach ($list in @('allow', 'deny', 'ask')) {
        $incoming = @()
        if (Test-HasProperty $Example.permissions $list) { $incoming = @($Example.permissions.$list) }
        $current = @()
        if (Test-HasProperty $Existing.permissions $list) { $current = @($Existing.permissions.$list) }
        if ($incoming.Count -eq 0 -and $current.Count -eq 0) { continue }
        $merged = Merge-StringList -Existing $current -Incoming $incoming
        $summary[$list] = [Math]::Max(0, $merged.Count - $current.Count)
        Add-ObjectProperty -Object $Existing.permissions -Name $list -Value $merged
    }

    if (-not (Test-HasProperty $Existing 'hooks') -or $null -eq $Existing.hooks) {
        Add-ObjectProperty -Object $Existing -Name 'hooks' -Value ([pscustomobject]@{})
    }
    # Drop this kit's entries wherever they are, keep everything else.
    foreach ($eventProp in @($Existing.hooks.PSObject.Properties)) {
        $kept = @()
        foreach ($group in @($eventProp.Value)) {
            if ($null -eq $group) { continue }
            if (Test-HasProperty $group 'hooks') {
                $own = @()
                foreach ($hook in @($group.hooks)) {
                    if (Test-KitHook -Hook $hook -Pattern $KitHookPattern) { $summary.HooksRemoved++ } else { $own += $hook }
                }
                if ($own.Count -eq 0) { continue }
                Add-ObjectProperty -Object $group -Name 'hooks' -Value ([object[]]$own)
            }
            $kept += $group
        }
        Add-ObjectProperty -Object $Existing.hooks -Name $eventProp.Name -Value ([object[]]$kept)
    }
    # Append the kit's groups.
    foreach ($eventProp in @($Example.hooks.PSObject.Properties)) {
        $groups = @()
        if (Test-HasProperty $Existing.hooks $eventProp.Name) { $groups = @($Existing.hooks.($eventProp.Name)) }
        foreach ($group in @($eventProp.Value)) {
            $groups += $group
            $summary.HooksAdded += @($group.hooks).Count
        }
        Add-ObjectProperty -Object $Existing.hooks -Name $eventProp.Name -Value ([object[]]$groups)
    }
    # An event left with no groups is removed rather than written as [].
    foreach ($eventProp in @($Existing.hooks.PSObject.Properties)) {
        if (@($eventProp.Value).Count -eq 0) { $Existing.hooks.PSObject.Properties.Remove($eventProp.Name) }
    }
    return $summary
}

function Write-JsonFile {
    # UTF-8 without BOM. Windows PowerShell 5.1's Out-File would write a BOM
    # or UTF-16, and Claude Code wants plain UTF-8.
    param($Object, [string]$Path)
    $json = $Object | ConvertTo-Json -Depth 20
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8)
}

function Install-KitConfiguration {
    param([string]$ClaudeDir)
    $examplePath = Join-Path $KitRoot "settings.example.json"
    $settingsPath = Join-Path $ClaudeDir "settings.json"
    $hooksDir = Join-Path $ClaudeDir "hooks"
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $defaultDir = Join-Path $homeDir ".claude"
    $customDir = ($ClaudeDir.TrimEnd('\', '/') -ne $defaultDir.TrimEnd('\', '/'))
    $hooksDirForward = ($hooksDir -replace '\\', '/')
    $kitHookPattern = '(\.claude[\\/]hooks|' + [regex]::Escape($hooksDirForward) + '|' + [regex]::Escape($hooksDir) + ')[\\/](' + ($KitHookNames -join '|') + ')\.ps1'

    New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
    Copy-Item -Path (Join-Path $KitRoot "hooks\*.ps1") -Destination $hooksDir -Force
    Write-Host "  ok   hooks copied to $hooksDir"

    $example = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json
    if ($customDir) { Convert-KitHookPath -Settings $example -HooksDirForward $hooksDirForward }

    if (Test-Path -LiteralPath $settingsPath) {
        $existing = $null
        try {
            $existing = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        } catch {
            throw "$settingsPath is not valid JSON ($($_.Exception.Message)). Fix or move it and rerun; nothing was changed."
        }
        if ($null -eq $existing) { $existing = [pscustomobject]@{} }
        $backup = $settingsPath + ".bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
        Copy-Item -LiteralPath $settingsPath -Destination $backup
        $summary = Merge-Configuration -Existing $existing -Example $example -KitHookPattern $kitHookPattern
        Write-JsonFile -Object $existing -Path $settingsPath
        Write-Host "  ok   merged into $settingsPath"
        Write-Host "       backup: $backup"
        Write-Host "       permissions added: allow +$($summary.allow), deny +$($summary.deny), ask +$($summary.ask)"
        Write-Host "       hooks: $($summary.HooksAdded) kit entries written, $($summary.HooksRemoved) older kit entries replaced, yours untouched"
    } else {
        $changed = $false
        $bash = Get-GitBashPath
        if ($bash) {
            if (-not (Test-HasProperty $example 'env')) { Add-ObjectProperty -Object $example -Name 'env' -Value ([pscustomobject]@{}) }
            if ([string]$example.env.CLAUDE_CODE_GIT_BASH_PATH -ne $bash) {
                Add-ObjectProperty -Object $example.env -Name 'CLAUDE_CODE_GIT_BASH_PATH' -Value $bash
                $changed = $true
            }
        } elseif (Test-HasProperty $example 'env') {
            $example.env.PSObject.Properties.Remove('CLAUDE_CODE_GIT_BASH_PATH')
            if (@($example.env.PSObject.Properties).Count -eq 0) { $example.PSObject.Properties.Remove('env') }
            $changed = $true
            Write-Host "  note Git Bash not found, so env.CLAUDE_CODE_GIT_BASH_PATH was left out. Claude Code uses"
            Write-Host "       PowerShell as its shell tool until Git for Windows is installed."
        }
        if ($changed -or $customDir) {
            Write-JsonFile -Object $example -Path $settingsPath
        } else {
            Copy-Item -LiteralPath $examplePath -Destination $settingsPath
        }
        Write-Host "  ok   created $settingsPath"
    }
}

Write-Host ""
Write-Host "claude-code-windows-kit installer"
Write-Host "---------------------------------"
$haveWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)

if ($SettingsOnly) {
    Write-Host ""
    Write-Host "-SettingsOnly: skipping steps 1 and 2"
} else {
    Write-Host ""
    Write-Host "Step 1 of 4: system packages"
    if ($haveWinget) {
        Install-WingetPackage -Id "Git.Git"                    -Label "Git for Windows (Git Bash for the Bash tool)"
        Install-WingetPackage -Id "OpenJS.NodeJS.LTS"          -Label "Node.js LTS (npx MCP servers, prettier)"
        Install-WingetPackage -Id "Microsoft.WindowsTerminal"  -Label "Windows Terminal"
        Install-WingetPackage -Id "Microsoft.VisualStudioCode" -Label "VS Code"
        Sync-SessionPath
    } else {
        Write-Host "  skip winget not found. Install 'App Installer' from the Microsoft Store to get it."
        Write-Host "       Git, Node, Windows Terminal and VS Code were not installed."
    }

    Write-Host ""
    Write-Host "Step 2 of 4: Claude Code"
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Write-Host "  ok   claude already on PATH; leaving it alone"
        Write-Host "       upgrade with 'claude update' (native installer) or 'winget upgrade Anthropic.ClaudeCode' (winget)"
    } elseif ($haveWinget) {
        Install-WingetPackage -Id "Anthropic.ClaudeCode" -Label "Claude Code"
        Sync-SessionPath
    } elseif (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Host "  ...  npm install -g @anthropic-ai/claude-code (winget missing, npm fallback)"
        npm install -g @anthropic-ai/claude-code | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "npm install failed. Use the native installer instead: irm https://claude.ai/install.ps1 | iex"
        }
    } else {
        Write-Host "  !!   neither winget nor npm is available. Install Claude Code with the native installer:"
        Write-Host "         irm https://claude.ai/install.ps1 | iex"
        Write-Host "       then rerun this script with -SettingsOnly for the settings and hooks."
        exit 1
    }
}

Write-Host ""
Write-Host "Step 3 of 4: settings and hooks"
$claudeDir = Get-ClaudeConfigDir
Install-KitConfiguration -ClaudeDir $claudeDir

Write-Host ""
Write-Host "Step 4 of 4: verify"
if (Get-Command claude -ErrorAction SilentlyContinue) {
    $claudeVersion = (claude --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "claude --version failed. Open a new terminal and run it by hand."
    }
    Write-Host "  ok   $claudeVersion"
} else {
    Write-Host "  note claude is not on PATH in this shell yet. Open a new terminal and run 'claude --version'."
}

Write-Host ""
Write-Host "Done. Run 'claude' in a project directory."
Write-Host "Hook logs: $claudeDir\guard-secrets.log, guard-git.log, format-on-edit.log"
Write-Host ""
