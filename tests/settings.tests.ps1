# Checks settings.example.json and runs every hook command in it through Git
# Bash, the way Claude Code runs hook commands on Windows. Plain PowerShell,
# no Pester.
#
#   powershell -ExecutionPolicy Bypass -File tests\settings.tests.ps1
#
# The Git Bash part copies the hooks into a throwaway home directory and sets
# HOME and USERPROFILE to it, so the command strings are exercised verbatim
# ($HOME expansion, the quoting, MSYS path conversion) without touching the
# real ~\.claude. Skipped when Git Bash is not installed.

[CmdletBinding()]
param(
    [string]$Shell = 'powershell.exe',
    [string]$TempRoot = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$repo = Get-RepoRoot
$examplePath = Join-Path $repo 'settings.example.json'

Write-Host "settings.example.json (test shell: $Shell)"
Write-Host ""
Write-Host "shape"
$settings = $null
try { $settings = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json } catch { $settings = $null }
Assert-True -Name 'parses as JSON' -Condition ($null -ne $settings)
if ($null -eq $settings) { Complete-TestRun -Suite 'settings' }

Assert-True -Name 'env.CLAUDE_CODE_GIT_BASH_PATH names a bash.exe' -Condition ([string]$settings.env.CLAUDE_CODE_GIT_BASH_PATH -like '*\bash.exe')
Assert-True -Name 'no Write(...) path rules (never checked by Claude Code)' -Condition (@($settings.permissions.deny | Where-Object { $_ -like 'Write(*' }).Count -eq 0)
Assert-True -Name 'every Read deny rule has an Edit twin' -Condition (@($settings.permissions.deny | Where-Object { $_ -like 'Read(*' } | ForEach-Object { 'Edit(' + $_.Substring(5) } | Where-Object { @($settings.permissions.deny) -notcontains $_ }).Count -eq 0)
Assert-True -Name 'no duplicate entries in allow/deny/ask' -Condition ((@($settings.permissions.allow + $settings.permissions.deny + $settings.permissions.ask) | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0)

$matchers = @{}
$commands = @()
foreach ($eventProp in $settings.hooks.PSObject.Properties) {
    foreach ($group in @($eventProp.Value)) {
        $matchers["$($eventProp.Name)|$($group.matcher)"] = $true
        foreach ($h in @($group.hooks)) {
            $commands += [pscustomobject]@{ Event = $eventProp.Name; Matcher = $group.matcher; Command = [string]$h.command; Timeout = $h.timeout; Type = [string]$h.type }
        }
    }
}
Assert-True -Name 'PreToolUse has Read|Edit|Write and Bash|PowerShell groups' -Condition ($matchers.ContainsKey('PreToolUse|Read|Edit|Write') -and $matchers.ContainsKey('PreToolUse|Bash|PowerShell'))
Assert-True -Name 'PostToolUse has an Edit|Write group' -Condition ($matchers.ContainsKey('PostToolUse|Edit|Write'))
Assert-True -Name 'Stop has a match-all group' -Condition ($matchers.ContainsKey('Stop|'))
Assert-True -Name 'four hook entries in total' -Condition ($commands.Count -eq 4) -Detail "count=$($commands.Count)"
foreach ($c in $commands) {
    # ConvertFrom-Json gives [int] on 5.1 and [long] on 7 for the same JSON number.
    $ok = $c.Type -eq 'command' -and ($c.Timeout -is [int] -or $c.Timeout -is [long]) -and $c.Timeout -gt 0 -and $c.Timeout -le 60
    $ok = $ok -and $c.Command -match '^powershell\.exe -NoProfile -ExecutionPolicy Bypass -File "\$HOME/\.claude/hooks/([a-z-]+\.ps1)"$'
    $script = if ($Matches) { $Matches[1] } else { '' }
    $ok = $ok -and $script -and (Test-Path -LiteralPath (Join-Path $repo "hooks\$script"))
    Assert-True -Name "$($c.Event) [$($c.Matcher)] runs an existing hook with a timeout" -Condition $ok -Detail $c.Command
}

Write-Host ""
Write-Host "hook commands run verbatim under Git Bash"
$bash = Get-GitBashExe
if (-not $bash) {
    Write-TestSkip 'Git Bash run' 'bash.exe not found'
} else {
    $tmp = Initialize-TestTempDir -Root $TempRoot -Prefix 'ccwk-settings'
    $fakeHome = Join-Path $tmp 'home'
    $hooksDir = Join-Path $fakeHome '.claude\hooks'
    New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
    Copy-Item -Path (Join-Path $repo 'hooks\*.ps1') -Destination $hooksDir
    $proj = Join-Path $tmp 'proj'
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    $txt = Join-Path $proj 'notes.txt'
    Set-Content -Path $txt -Value 'plain' -NoNewline
    $bashEnv = @{
        HOME        = ($fakeHome -replace '\\', '/')
        USERPROFILE = $fakeHome
        HOMEDRIVE   = (Split-Path -Qualifier $fakeHome)
        HOMEPATH    = (Split-Path -NoQualifier $fakeHome)
    }

    function Invoke-HookViaBash {
        param([string]$Command, [string]$Payload)
        # bash.exe -c "<command>" with the inner double quotes escaped for the
        # Windows command line; $HOME stays literal for bash to expand.
        $arguments = '-c "' + ($Command -replace '"', '\"') + '"'
        return Invoke-ProcessWithInput -FileName $bash -Arguments $arguments -StandardInput $Payload -Environment $bashEnv -WorkingDirectory $proj -TimeoutMs 60000
    }

    $byScript = @{}
    foreach ($c in $commands) { if ($c.Command -match '([a-z-]+)\.ps1"$') { $byScript[$Matches[1]] = $c.Command } }

    $r = Invoke-HookViaBash -Command $byScript['guard-secrets'] -Payload (ConvertTo-HookPayload -ToolName 'Read' -ToolInput @{ file_path = '.env' } -Cwd $proj)
    Assert-ExitCode -Name 'guard-secrets blocks Read .env (exit 2)' -Expected 2 -Result $r
    Assert-True -Name 'guard-secrets reason reaches stderr through bash' -Condition ($r.StdErr -match 'guard-secrets: refusing Read') -Detail $r.StdErr
    $r = Invoke-HookViaBash -Command $byScript['guard-secrets'] -Payload (ConvertTo-HookPayload -ToolName 'Read' -ToolInput @{ file_path = 'src/main.py' } -Cwd $proj)
    Assert-ExitCode -Name 'guard-secrets allows src/main.py' -Expected 0 -Result $r

    $r = Invoke-HookViaBash -Command $byScript['guard-git'] -Payload (ConvertTo-HookPayload -ToolName 'Bash' -ToolInput @{ command = 'git push --force origin main' } -Cwd $proj)
    Assert-ExitCode -Name 'guard-git blocks a force push to main (exit 2)' -Expected 2 -Result $r
    Assert-True -Name 'guard-git deny JSON reaches stdout through bash' -Condition ($r.StdOut -match '"permissionDecision":"deny"') -Detail $r.StdOut
    $r = Invoke-HookViaBash -Command $byScript['guard-git'] -Payload (ConvertTo-HookPayload -ToolName 'Bash' -ToolInput @{ command = 'git status' } -Cwd $proj)
    Assert-ExitCode -Name 'guard-git allows git status' -Expected 0 -Result $r

    $r = Invoke-HookViaBash -Command $byScript['format-on-edit'] -Payload (ConvertTo-HookPayload -ToolName 'Edit' -ToolInput @{ file_path = $txt } -Cwd $proj -EventName 'PostToolUse')
    Assert-ExitCode -Name 'format-on-edit exits 0 on a .txt' -Expected 0 -Result $r
    Assert-True -Name 'format-on-edit wrote its log under the fake home' -Condition (Test-Path -LiteralPath (Join-Path $fakeHome '.claude\format-on-edit.log'))

    $r = Invoke-HookViaBash -Command $byScript['notify'] -Payload ('{"session_id":"kit-tests","cwd":"' + ($proj -replace '\\', '\\\\') + '","hook_event_name":"Stop","stop_hook_active":false}')
    Assert-ExitCode -Name 'notify exits 0 on a Stop payload' -Expected 0 -Result $r
    Assert-True -Name 'notify returns within 5 s' -Condition ($r.ElapsedMs -lt 5000) -Detail "took $($r.ElapsedMs) ms"

    Assert-True -Name 'guard logs landed under the fake home, not the real one' -Condition ((Test-Path -LiteralPath (Join-Path $fakeHome '.claude\guard-secrets.log')) -and (Test-Path -LiteralPath (Join-Path $fakeHome '.claude\guard-git.log')))
    Clear-TestTempDir -Path $tmp
}

Complete-TestRun -Suite 'settings'
