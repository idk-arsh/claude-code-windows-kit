# Tests for the settings merge in install.ps1. Plain PowerShell, no Pester.
#
#   powershell -ExecutionPolicy Bypass -File tests\install.tests.ps1
#
# Runs install.ps1 -SettingsOnly in a child process with CLAUDE_CONFIG_DIR
# (and, for the default-location case, USERPROFILE) pointed at throwaway
# directories, so the real ~\.claude is never touched. Covers: no settings
# file, an existing file with extra keys and overlapping entries, an existing
# file carrying the v0.1 %USERPROFILE% hook commands, and an unreadable file.

[CmdletBinding()]
param(
    [string]$Shell = 'powershell.exe',
    [string]$TempRoot = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$repo = Get-RepoRoot
$install = Join-Path $repo 'install.ps1'
$example = Get-Content -LiteralPath (Join-Path $repo 'settings.example.json') -Raw | ConvertFrom-Json
$tmp = Initialize-TestTempDir -Root $TempRoot -Prefix 'ccwk-install'
$hookFiles = @('guard-secrets.ps1', 'guard-git.ps1', 'format-on-edit.ps1', 'notify.ps1')

function Invoke-Install {
    param([hashtable]$Environment)
    $result = Invoke-PowerShellFile -Shell $Shell -File $install -ArgumentList @('-SettingsOnly') -Environment $Environment -WorkingDirectory $repo -TimeoutMs 120000
    return $result
}

function Read-SettingsFile {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-HookCommand {
    param($Settings, [string]$EventName)
    $out = @()
    foreach ($group in @($Settings.hooks.$EventName)) { foreach ($h in @($group.hooks)) { $out += [string]$h.command } }
    return $out
}

function Test-Utf8NoBom {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

Write-Host "install.ps1 -SettingsOnly under $Shell"

# ---- A. no settings file, default location (USERPROFILE moved) ----
Write-Host ""
Write-Host "A. no settings file at the default location"
$homeA = Join-Path $tmp 'homeA'
New-Item -ItemType Directory -Path $homeA -Force | Out-Null
$envA = @{ USERPROFILE = $homeA; HOME = $homeA; HOMEDRIVE = (Split-Path -Qualifier $homeA); HOMEPATH = (Split-Path -NoQualifier $homeA); CLAUDE_CONFIG_DIR = $null }
$rA = Invoke-Install -Environment $envA
Assert-ExitCode -Name 'exits 0' -Expected 0 -Result $rA
$settingsA = Join-Path $homeA '.claude\settings.json'
Assert-True -Name 'settings.json created under USERPROFILE\.claude' -Condition (Test-Path -LiteralPath $settingsA) -Detail $rA.StdOut
if (Test-Path -LiteralPath $settingsA) {
    $a = Read-SettingsFile $settingsA
    Assert-True -Name 'file is UTF-8 without BOM' -Condition (Test-Utf8NoBom $settingsA)
    Assert-True -Name 'permissions match the example' -Condition ((@($a.permissions.allow) -join '|') -eq (@($example.permissions.allow) -join '|') -and (@($a.permissions.deny) -join '|') -eq (@($example.permissions.deny) -join '|') -and (@($a.permissions.ask) -join '|') -eq (@($example.permissions.ask) -join '|'))
    Assert-True -Name 'hook commands keep the $HOME/.claude/hooks form' -Condition (((Get-HookCommand $a 'PreToolUse') + (Get-HookCommand $a 'PostToolUse') + (Get-HookCommand $a 'Stop') | Where-Object { $_ -notmatch '\$HOME/\.claude/hooks/(guard-secrets|guard-git|format-on-edit|notify)\.ps1' }).Count -eq 0)
    $bashValue = [string]$a.env.CLAUDE_CODE_GIT_BASH_PATH
    if ($bashValue) {
        Assert-True -Name 'env.CLAUDE_CODE_GIT_BASH_PATH points at an existing bash.exe' -Condition ((Test-Path -LiteralPath $bashValue) -and $bashValue -like '*bash.exe') -Detail $bashValue
    } else {
        Assert-True -Name 'no Git Bash found, env key dropped' -Condition ($rA.StdOut -match 'Git Bash not found')
    }
    $copied = @($hookFiles | Where-Object { Test-Path -LiteralPath (Join-Path $homeA ".claude\hooks\$_") })
    Assert-True -Name 'four hook scripts copied' -Condition ($copied.Count -eq 4) -Detail ($copied -join ',')
    Assert-True -Name 'no backup made when there was nothing to back up' -Condition (@(Get-ChildItem -Path (Join-Path $homeA '.claude') -Filter 'settings.json.bak-*').Count -eq 0)
}

# ---- B. existing file with extra keys and overlapping entries ----
Write-Host ""
Write-Host "B. existing settings with extra keys, own hooks and overlapping permissions"
$dirB = Join-Path $tmp 'configB'
New-Item -ItemType Directory -Path $dirB -Force | Out-Null
$originalB = @'
{
  "model": "opus",
  "theme": "dark",
  "autoUpdatesChannel": "stable",
  "permissions": {
    "allow": ["Bash(cargo test:*)", "Bash(git status)"],
    "deny": ["Read(.env)", "Read(~/.kube/**)"],
    "additionalDirectories": ["C:\\work\\shared"],
    "defaultMode": "acceptEdits"
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "node C:/me/hooks/my-guard.js", "timeout": 5 } ] }
    ],
    "SessionStart": [
      { "matcher": "startup", "hooks": [ { "type": "command", "command": "echo hi" } ] }
    ]
  },
  "statusLine": { "type": "command", "command": "echo status" }
}
'@
$settingsB = Join-Path $dirB 'settings.json'
[System.IO.File]::WriteAllText($settingsB, $originalB, (New-Object System.Text.UTF8Encoding($false)))
$rB = Invoke-Install -Environment @{ CLAUDE_CONFIG_DIR = $dirB }
Assert-ExitCode -Name 'exits 0' -Expected 0 -Result $rB
$b = Read-SettingsFile $settingsB
$backups = @(Get-ChildItem -Path $dirB -Filter 'settings.json.bak-*')
Assert-True -Name 'backup written first' -Condition ($backups.Count -eq 1)
if ($backups.Count -eq 1) {
    Assert-True -Name 'backup is the original byte for byte' -Condition ((Get-Content -LiteralPath $backups[0].FullName -Raw) -eq $originalB)
}
Assert-True -Name 'file is UTF-8 without BOM' -Condition (Test-Utf8NoBom $settingsB)
Assert-True -Name 'model, theme, autoUpdatesChannel kept' -Condition ($b.model -eq 'opus' -and $b.theme -eq 'dark' -and $b.autoUpdatesChannel -eq 'stable')
Assert-True -Name 'statusLine kept' -Condition ($b.statusLine.command -eq 'echo status')
Assert-True -Name 'permissions.additionalDirectories and defaultMode kept' -Condition (@($b.permissions.additionalDirectories)[0] -eq 'C:\work\shared' -and $b.permissions.defaultMode -eq 'acceptEdits')
$allowB = @($b.permissions.allow)
Assert-True -Name 'allow: user entries first, in their order' -Condition ($allowB[0] -eq 'Bash(cargo test:*)' -and $allowB[1] -eq 'Bash(git status)')
Assert-True -Name 'allow: overlapping entry not duplicated' -Condition (@($allowB | Where-Object { $_ -eq 'Bash(git status)' }).Count -eq 1)
Assert-True -Name 'allow: every example entry present' -Condition (@($example.permissions.allow | Where-Object { $allowB -notcontains $_ }).Count -eq 0)
Assert-True -Name 'allow: count is user + new example entries' -Condition ($allowB.Count -eq (2 + @($example.permissions.allow).Count - 1)) -Detail "count=$($allowB.Count)"
$denyB = @($b.permissions.deny)
Assert-True -Name 'deny: user-only entry kept, example entries added, no duplicate Read(.env)' -Condition (($denyB -contains 'Read(~/.kube/**)') -and (@($denyB | Where-Object { $_ -eq 'Read(.env)' }).Count -eq 1) -and ($denyB.Count -eq (2 + @($example.permissions.deny).Count - 1)))
Assert-True -Name 'ask: added from the example' -Condition ((@($b.permissions.ask) -join '|') -eq (@($example.permissions.ask) -join '|'))
$preB = @($b.hooks.PreToolUse)
Assert-True -Name 'PreToolUse: user group first, then the two kit groups' -Condition ($preB.Count -eq 3 -and $preB[0].matcher -eq 'Bash' -and $preB[0].hooks[0].command -eq 'node C:/me/hooks/my-guard.js' -and $preB[1].matcher -eq 'Read|Edit|Write' -and $preB[2].matcher -eq 'Bash|PowerShell') -Detail ("matchers: " + (($preB | ForEach-Object { $_.matcher }) -join ','))
Assert-True -Name 'user hook timeout kept' -Condition ($preB[0].hooks[0].timeout -eq 5)
Assert-True -Name 'SessionStart untouched' -Condition (@($b.hooks.SessionStart).Count -eq 1 -and $b.hooks.SessionStart[0].hooks[0].command -eq 'echo hi')
Assert-True -Name 'PostToolUse and Stop added' -Condition (@($b.hooks.PostToolUse).Count -eq 1 -and @($b.hooks.Stop).Count -eq 1)
$dirBForward = ($dirB -replace '\\', '/')
$kitCmdsB = @((Get-HookCommand $b 'PreToolUse') + (Get-HookCommand $b 'PostToolUse') + (Get-HookCommand $b 'Stop') | Where-Object { $_ -match '(guard-secrets|guard-git|format-on-edit|notify)\.ps1' })
Assert-True -Name 'kit hook commands point at the custom config dir (forward slashes)' -Condition ($kitCmdsB.Count -eq 4 -and @($kitCmdsB | Where-Object { $_ -notlike "*-File `"$dirBForward/hooks/*.ps1`"" }).Count -eq 0) -Detail ($kitCmdsB -join ' || ')
Assert-True -Name 'env not added to an existing file' -Condition (-not ($b.PSObject.Properties['env']))
Assert-True -Name 'four hook scripts copied to the custom dir' -Condition (@($hookFiles | Where-Object { Test-Path -LiteralPath (Join-Path $dirB "hooks\$_") }).Count -eq 4)

Write-Host ""
Write-Host "B2. running the merge a second time changes nothing but the backup"
$before = Get-Content -LiteralPath $settingsB -Raw
$rB2 = Invoke-Install -Environment @{ CLAUDE_CONFIG_DIR = $dirB }
Assert-ExitCode -Name 'exits 0' -Expected 0 -Result $rB2
Assert-True -Name 'second run is idempotent' -Condition ((Get-Content -LiteralPath $settingsB -Raw) -eq $before)
Assert-True -Name 'second backup written' -Condition (@(Get-ChildItem -Path $dirB -Filter 'settings.json.bak-*').Count -eq 2)
Assert-True -Name 'summary reports 4 replaced, 4 written' -Condition ($rB2.StdOut -match '4 kit entries written, 4 older kit entries replaced') -Detail $rB2.StdOut

# ---- C. v0.1 file with %USERPROFILE% hook commands ----
Write-Host ""
Write-Host "C. existing settings carrying the v0.1 %USERPROFILE% hook commands"
$dirC = Join-Path $tmp 'configC'
New-Item -ItemType Directory -Path $dirC -Force | Out-Null
$originalC = @'
{
  "permissions": {
    "allow": ["Bash(git status)"],
    "deny": ["Bash(git push --force:*)"]
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Edit|Write", "hooks": [ { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\hooks\\guard-secrets.ps1\"" } ] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\hooks\\notify.ps1\"" },
        { "type": "command", "command": "echo my-own-stop-hook" }
      ] }
    ]
  }
}
'@
$settingsC = Join-Path $dirC 'settings.json'
[System.IO.File]::WriteAllText($settingsC, $originalC, (New-Object System.Text.UTF8Encoding($false)))
$rC = Invoke-Install -Environment @{ CLAUDE_CONFIG_DIR = $dirC }
Assert-ExitCode -Name 'exits 0' -Expected 0 -Result $rC
$c = Read-SettingsFile $settingsC
$allCmdsC = @((Get-HookCommand $c 'PreToolUse') + (Get-HookCommand $c 'PostToolUse') + (Get-HookCommand $c 'Stop'))
Assert-True -Name 'no %USERPROFILE% command survives' -Condition (@($allCmdsC | Where-Object { $_ -match 'USERPROFILE' }).Count -eq 0) -Detail ($allCmdsC -join ' || ')
Assert-True -Name 'old Edit|Write group dropped, two kit PreToolUse groups present' -Condition (@($c.hooks.PreToolUse).Count -eq 2 -and (@($c.hooks.PreToolUse | ForEach-Object { $_.matcher }) -join ',') -eq 'Read|Edit|Write,Bash|PowerShell')
$stopC = @($c.hooks.Stop)
Assert-True -Name 'Stop: user hook kept in its group, kit entry removed, kit group appended' -Condition ($stopC.Count -eq 2 -and @($stopC[0].hooks).Count -eq 1 -and $stopC[0].hooks[0].command -eq 'echo my-own-stop-hook' -and $stopC[1].hooks[0].command -like '*notify.ps1*') -Detail (($stopC | ForEach-Object { @($_.hooks).Count }) -join ',')
Assert-True -Name 'user deny rule kept alongside the example rules' -Condition ((@($c.permissions.deny) -contains 'Bash(git push --force:*)') -and (@($c.permissions.deny) -contains 'Bash(git push*--force*)'))
Assert-True -Name 'summary reports 2 older kit entries replaced' -Condition ($rC.StdOut -match '2 older kit entries replaced') -Detail $rC.StdOut

# ---- D. unreadable file is left alone ----
Write-Host ""
Write-Host "D. settings.json that is not JSON"
$dirD = Join-Path $tmp 'configD'
New-Item -ItemType Directory -Path $dirD -Force | Out-Null
$settingsD = Join-Path $dirD 'settings.json'
Set-Content -LiteralPath $settingsD -Value '{ "model": "opus", ' -NoNewline
$rD = Invoke-Install -Environment @{ CLAUDE_CONFIG_DIR = $dirD }
Assert-True -Name 'exits non-zero' -Condition ($rD.ExitCode -ne 0) -Detail "exit=$($rD.ExitCode)"
Assert-True -Name 'file untouched' -Condition ((Get-Content -LiteralPath $settingsD -Raw) -eq '{ "model": "opus", ')
Assert-True -Name 'no backup written' -Condition (@(Get-ChildItem -Path $dirD -Filter 'settings.json.bak-*').Count -eq 0)
Assert-True -Name 'error names the file' -Condition (($rD.StdErr + $rD.StdOut) -match 'not valid JSON') -Detail ($rD.StdErr)

Clear-TestTempDir -Path $tmp
Complete-TestRun -Suite 'install'
