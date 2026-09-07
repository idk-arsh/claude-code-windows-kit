# Test matrix for hooks/guard-git.ps1. Plain PowerShell, no Pester.
#
#   powershell -ExecutionPolicy Bypass -File tests\guard-git.tests.ps1
#   pwsh -File tests\guard-git.tests.ps1 -Shell pwsh
#
# Each case pipes a PreToolUse payload into the hook the way Claude Code does
# and checks the exit code: 2 means blocked, 0 means allowed. Cases that
# depend on the current branch use throwaway git repositories created under
# the temp directory. Exits 1 if any case fails.

[CmdletBinding()]
param(
    [string]$Shell = 'powershell.exe',
    [string]$TempRoot = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$hook = Join-Path (Get-RepoRoot) 'hooks\guard-git.ps1'
$tmp = Initialize-TestTempDir -Root $TempRoot -Prefix 'ccwk-guard-git'
$fakeHome = Join-Path $tmp 'home'
$notRepo = Join-Path $tmp 'not-a-repo'
New-Item -ItemType Directory -Path $fakeHome, $notRepo -Force | Out-Null
$hookEnv = @{ USERPROFILE = $fakeHome; HOME = $fakeHome; HOMEDRIVE = (Split-Path -Qualifier $fakeHome); HOMEPATH = (Split-Path -NoQualifier $fakeHome) }

function Initialize-GitFixture {
    param([string]$Path, [string]$Branch)
    $ErrorActionPreference = 'Continue'
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & git -C $Path init -q
    & git -C $Path symbolic-ref HEAD "refs/heads/$Branch"
    Set-Content -Path (Join-Path $Path 'README.md') -Value 'fixture'
    & git -C $Path add README.md
    & git -C $Path -c user.name=kit-tests -c user.email=kit-tests@example.com -c commit.gpgsign=false commit -q -m fixture
    $current = (& git -C $Path symbolic-ref --short -q HEAD)
    if ($current -ne $Branch) { throw "fixture at $Path is on '$current', expected '$Branch'" }
    return $Path
}

$haveGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
$repoMain = $null
$repoFeature = $null
if ($haveGit) {
    $repoMain = Initialize-GitFixture -Path (Join-Path $tmp 'repo-main') -Branch 'main'
    $repoFeature = Initialize-GitFixture -Path (Join-Path $tmp 'repo-feature') -Branch 'feature'
}

function Test-Guard {
    param(
        [string]$Name,
        [string]$Command,
        [int]$Expect,
        [string]$Cwd = $notRepo,
        [string]$Tool = 'Bash'
    )
    $payload = ConvertTo-HookPayload -ToolName $Tool -ToolInput @{ command = $Command } -Cwd $Cwd
    $result = Invoke-Hook -Shell $Shell -HookPath $hook -Payload $payload -Environment $hookEnv -WorkingDirectory $notRepo
    Assert-ExitCode -Name $Name -Expected $Expect -Result $result
    return $result
}

Write-Host "guard-git.ps1 under $Shell"
Write-Host ""
Write-Host "git push"
$blocked = Test-Guard 'force push to main' 'git push --force origin main' 2
Test-Guard '-f to master' 'git push -f origin master' 2 | Out-Null
Test-Guard 'flag after the refspec' 'git push origin main --force' 2 | Out-Null
Test-Guard '+refspec to main' 'git push origin +main' 2 | Out-Null
Test-Guard 'HEAD:main with --force' 'git push --force origin HEAD:main' 2 | Out-Null
Test-Guard 'refs/heads/main spelled out' 'git push --force origin refs/heads/main' 2 | Out-Null
Test-Guard '--force-with-lease to main is refused' 'git push --force-with-lease origin main' 2 | Out-Null
Test-Guard '-u and -f together' 'git push -u origin main -f' 2 | Out-Null
Test-Guard '-o value is skipped, force still seen' 'git push -o ci.skip origin main --force' 2 | Out-Null
Test-Guard '--all with --force' 'git push --force --all origin' 2 | Out-Null
Test-Guard ':main deletes the remote branch' 'git push origin :main' 2 | Out-Null
Test-Guard '--delete main' 'git push --delete origin master' 2 | Out-Null
Test-Guard 'chained after cd' 'cd src && git push --force origin main' 2 | Out-Null
Test-Guard 'chained after semicolon' 'git status; git push --force origin main' 2 | Out-Null
Test-Guard 'piped' 'git push --force origin main | cat' 2 | Out-Null
Test-Guard 'flag on a continuation line' "git push origin main \\`n  --force" 2 | Out-Null
Test-Guard 'wrapped in bash -c' 'bash -c "git push --force origin main"' 2 | Out-Null
Test-Guard 'same command via the PowerShell tool' 'git push --force origin main' 2 -Tool 'PowerShell' | Out-Null
Test-Guard 'no branch, cwd is not a repo (fail closed)' 'git push --force' 2 -Cwd $notRepo | Out-Null
Test-Guard 'no branch, no cwd in payload (fail closed)' 'git push --force' 2 -Cwd '' | Out-Null
Test-Guard 'refspec built by shell expansion, cwd not a repo' 'git push --force origin $(git branch --show-current)' 2 | Out-Null
if ($haveGit) {
    Test-Guard 'no branch, cwd on main' 'git push --force' 2 -Cwd $repoMain | Out-Null
    Test-Guard 'remote only, cwd on main' 'git push --force origin' 2 -Cwd $repoMain | Out-Null
    Test-Guard 'HEAD refspec, cwd on main' 'git push -f origin HEAD' 2 -Cwd $repoMain | Out-Null
    Test-Guard 'no branch, cwd on feature' 'git push --force' 0 -Cwd $repoFeature | Out-Null
    Test-Guard '--force-with-lease, cwd on feature' 'git push --force-with-lease' 0 -Cwd $repoFeature | Out-Null
    Test-Guard 'cd into the main repo first' "cd `"$repoMain`" && git push --force" 2 -Cwd $repoFeature | Out-Null
    Test-Guard 'git -C main repo' "git -C `"$repoMain`" push --force" 2 -Cwd $repoFeature | Out-Null
    $msys = '/' + $repoMain.Substring(0, 1).ToLower() + ($repoMain.Substring(2) -replace '\\', '/')
    Test-Guard 'git -C with an msys path' "git -C $msys push --force" 2 -Cwd $repoFeature | Out-Null
} else {
    Write-TestSkip 'current-branch cases' 'git not on PATH'
}
Test-Guard 'plain push' 'git push origin feature' 0 | Out-Null
Test-Guard 'set upstream, no force' 'git push -u origin main' 0 | Out-Null
Test-Guard 'force to a feature branch' 'git push --force origin feature' 0 | Out-Null
Test-Guard '--force-with-lease to a feature branch' 'git push --force-with-lease origin feature' 0 | Out-Null
Test-Guard '+refspec to a feature branch' 'git push origin +feature' 0 | Out-Null
Test-Guard 'delete a feature branch' 'git push --delete origin feature' 0 | Out-Null
Test-Guard 'a branch merely named like main' 'git push --force origin maintenance' 0 | Out-Null

Write-Host ""
Write-Host "git reset, checkout, restore, clean, branch"
Test-Guard 'reset --hard origin/main' 'git reset --hard origin/main' 2 | Out-Null
Test-Guard 'reset --hard @{u}' 'git reset --hard @{u}' 2 | Out-Null
Test-Guard 'reset --hard refs/remotes' 'git reset --hard refs/remotes/origin/feature' 2 | Out-Null
Test-Guard 'reset --hard HEAD~1 is local' 'git reset --hard HEAD~1' 0 | Out-Null
Test-Guard 'reset --hard alone is local' 'git reset --hard' 0 | Out-Null
Test-Guard 'reset --soft origin/main' 'git reset --soft origin/main' 0 | Out-Null
Test-Guard 'checkout -- .' 'git checkout -- .' 2 | Out-Null
Test-Guard 'checkout .' 'git checkout .' 2 | Out-Null
Test-Guard 'checkout HEAD -- .' 'git checkout HEAD -- .' 2 | Out-Null
Test-Guard 'checkout one file' 'git checkout -- src/app.js' 0 | Out-Null
Test-Guard 'checkout a branch' 'git checkout main' 0 | Out-Null
Test-Guard 'checkout -b' 'git checkout -b feature/x' 0 | Out-Null
Test-Guard 'restore .' 'git restore .' 2 | Out-Null
Test-Guard 'restore :/' 'git restore :/' 2 | Out-Null
Test-Guard 'restore -S -W .' 'git restore -S -W .' 2 | Out-Null
Test-Guard 'restore --staged --worktree .' 'git restore --staged --worktree .' 2 | Out-Null
Test-Guard 'restore --staged . only touches the index' 'git restore --staged .' 0 | Out-Null
Test-Guard 'restore one file' 'git restore src/app.js' 0 | Out-Null
Test-Guard 'clean -fd' 'git clean -fd' 2 | Out-Null
Test-Guard 'clean --force' 'git clean --force' 2 | Out-Null
Test-Guard 'clean -fdx' 'git clean -fdx' 2 | Out-Null
Test-Guard 'clean -n' 'git clean -n' 0 | Out-Null
Test-Guard 'clean -fdn is a dry run' 'git clean -fdn' 0 | Out-Null
Test-Guard 'branch -D main' 'git branch -D main' 2 | Out-Null
Test-Guard 'branch --delete --force master' 'git branch --delete --force master' 2 | Out-Null
Test-Guard 'branch -D feature' 'git branch -D feature' 0 | Out-Null
Test-Guard 'branch -d main (git refuses unmerged itself)' 'git branch -d main' 0 | Out-Null
Test-Guard 'branch list' 'git branch -a' 0 | Out-Null

Write-Host ""
Write-Host "rm"
Test-Guard 'rm -rf /' 'rm -rf /' 2 | Out-Null
Test-Guard 'rm -fr ~' 'rm -fr ~' 2 | Out-Null
Test-Guard 'rm -r -f .' 'rm -r -f .' 2 | Out-Null
Test-Guard 'rm -rf *' 'rm -rf *' 2 | Out-Null
Test-Guard 'rm -rf ./' 'rm -rf ./' 2 | Out-Null
Test-Guard 'rm -rf ..' 'rm -rf ..' 2 | Out-Null
Test-Guard 'rm -rf "C:\"' 'rm -rf "C:\"' 2 | Out-Null
Test-Guard 'rm -rf /c' 'rm -rf /c' 2 | Out-Null
Test-Guard 'rm -rf /mnt/c/' 'rm -rf /mnt/c/' 2 | Out-Null
Test-Guard 'rm -rf $HOME' 'rm -rf $HOME' 2 | Out-Null
Test-Guard 'rm -rf "$HOME"' 'rm -rf "$HOME"' 2 | Out-Null
Test-Guard 'rm --recursive --force ./' 'rm --recursive --force ./' 2 | Out-Null
Test-Guard 'rm -Rf /*' 'rm -Rf /*' 2 | Out-Null
Test-Guard 'rm -rfv /' 'rm -rfv /' 2 | Out-Null
Test-Guard 'sudo rm --no-preserve-root' 'sudo rm -rf --no-preserve-root /' 2 | Out-Null
Test-Guard 'rm -rf -- /' 'rm -rf -- /' 2 | Out-Null
Test-Guard 'second segment is the bad one' 'rm -rf ./build && rm -rf /' 2 | Out-Null
Test-Guard 'full path to rm' '/usr/bin/rm -rf ~' 2 | Out-Null
Test-Guard 'sh -c wrapper' "sh -c 'rm -rf /'" 2 | Out-Null
Test-Guard 'rm -rf ./build' 'rm -rf ./build' 0 | Out-Null
Test-Guard 'rm -rf node_modules dist' 'rm -rf node_modules dist' 0 | Out-Null
Test-Guard 'rm -rf a deep msys path' 'rm -rf /c/Users/x/proj/build' 0 | Out-Null
Test-Guard 'rm -f one file' 'rm -f /tmp/x.log' 0 | Out-Null
Test-Guard 'rm -rf .cache' 'rm -rf .cache' 0 | Out-Null
Test-Guard 'echo of a bad command is text' 'echo "rm -rf /"' 0 | Out-Null
Test-Guard 'commit message containing rm -rf' 'git commit -m "remove rm -rf / from script"' 0 | Out-Null
Test-Guard 'grep -r is not rm -r' 'grep -r "force" .' 0 | Out-Null

Write-Host ""
Write-Host "Remove-Item"
Test-Guard 'Remove-Item -Recurse -Force C:\' 'Remove-Item -Recurse -Force C:\' 2 -Tool 'PowerShell' | Out-Null
Test-Guard 'Remove-Item -Path "C:\" -Recurse -Force' 'Remove-Item -Path "C:\" -Recurse -Force' 2 -Tool 'PowerShell' | Out-Null
Test-Guard 'Remove-Item * -Recurse -Force' 'Remove-Item * -Recurse -Force' 2 -Tool 'PowerShell' | Out-Null
Test-Guard 'Remove-Item -Recurse -Force $env:USERPROFILE' 'Remove-Item -Recurse -Force $env:USERPROFILE' 2 -Tool 'PowerShell' | Out-Null
Test-Guard 'Remove-Item -Recurse -Force ~' 'Remove-Item -Recurse -Force ~' 2 -Tool 'PowerShell' | Out-Null
Test-Guard 'Remove-Item -LiteralPath . -Recurse' 'Remove-Item -LiteralPath . -Recurse -Force' 2 -Tool 'PowerShell' | Out-Null
Test-Guard 'ri -r -fo ~' 'ri -r -fo ~' 2 -Tool 'PowerShell' | Out-Null
Test-Guard 'Remove-Item -Recurse:$true D:\' 'Remove-Item -Recurse:$true -Force D:\' 2 -Tool 'PowerShell' | Out-Null
Test-Guard 'powershell -Command wrapper from Bash' 'powershell -Command "Remove-Item -Recurse -Force C:\"' 2 | Out-Null
Test-Guard 'pwsh -c wrapper, unquoted' 'pwsh -c Remove-Item -Recurse -Force C:\' 2 | Out-Null
$encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes('Remove-Item -Recurse -Force C:\'))
Test-Guard 'powershell -EncodedCommand wrapper' "powershell -EncodedCommand $encoded" 2 | Out-Null
Test-Guard 'cmd /c rmdir /s /q C:\' 'cmd /c "rmdir /s /q C:\"' 2 | Out-Null
Test-Guard 'Remove-Item -Recurse -Force .\build' 'Remove-Item -Recurse -Force .\build' 0 -Tool 'PowerShell' | Out-Null
Test-Guard 'Remove-Item C:\proj\out -Recurse' 'Remove-Item C:\proj\out -Recurse -Force' 0 -Tool 'PowerShell' | Out-Null
Test-Guard 'Remove-Item one file' 'Remove-Item .\a.log -Force' 0 -Tool 'PowerShell' | Out-Null
Test-Guard 'Get-ChildItem -Recurse is not a delete' 'Get-ChildItem -Recurse -Force C:\' 0 -Tool 'PowerShell' | Out-Null

Write-Host ""
Write-Host "payload handling"
Test-Guard 'ordinary command' 'npm test' 0 | Out-Null
Test-Guard 'git log piped' 'git log --oneline -5 | head' 0 | Out-Null
$r = Invoke-Hook -Shell $Shell -HookPath $hook -Payload '{"tool_name":"Bash","tool_input":{}}' -Environment $hookEnv -WorkingDirectory $notRepo
Assert-ExitCode -Name 'no command field' -Expected 0 -Result $r
$r = Invoke-Hook -Shell $Shell -HookPath $hook -Payload '{"tool_name":"Bash","tool_input":null}' -Environment $hookEnv -WorkingDirectory $notRepo
Assert-ExitCode -Name 'tool_input null' -Expected 0 -Result $r
$r = Invoke-Hook -Shell $Shell -HookPath $hook -Payload '{"tool_name": "Bash", "tool_input": {' -Environment $hookEnv -WorkingDirectory $notRepo
Assert-ExitCode -Name 'malformed JSON' -Expected 0 -Result $r
$r = Invoke-Hook -Shell $Shell -HookPath $hook -Payload '' -Environment $hookEnv -WorkingDirectory $notRepo
Assert-ExitCode -Name 'empty stdin' -Expected 0 -Result $r
$r = Invoke-Hook -Shell $Shell -HookPath $hook -Payload $null -Environment $hookEnv -WorkingDirectory $notRepo
Assert-ExitCode -Name 'closed stdin' -Expected 0 -Result $r

Write-Host ""
Write-Host "block output"
$decision = $null
try { $decision = $blocked.StdOut | ConvertFrom-Json } catch { $decision = $null }
Assert-True -Name 'stdout is a JSON deny decision' -Condition ($null -ne $decision -and $decision.hookSpecificOutput.permissionDecision -eq 'deny' -and $decision.hookSpecificOutput.hookEventName -eq 'PreToolUse') -Detail $blocked.StdOut
Assert-True -Name 'stderr carries the reason' -Condition ($blocked.StdErr -match 'guard-git: git push with a force flag') -Detail $blocked.StdErr
Assert-True -Name 'decision reason matches stderr' -Condition ($null -ne $decision -and $blocked.StdErr.Trim() -eq $decision.hookSpecificOutput.permissionDecisionReason) -Detail $blocked.StdErr
$marker = 'kit-marker-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
Test-Guard 'blocked command for the log check' "git push --force origin main # $marker" 2 | Out-Null
$logCandidates = @((Join-Path $fakeHome '.claude\guard-git.log'), (Join-Path $HOME '.claude\guard-git.log'))
$logged = $false
foreach ($candidate in $logCandidates) {
    if ((Test-Path -LiteralPath $candidate) -and ((Get-Content -LiteralPath $candidate -Raw) -match [regex]::Escape($marker))) { $logged = $true }
}
Assert-True -Name 'block written to guard-git.log' -Condition $logged -Detail ($logCandidates -join ' | ')

Clear-TestTempDir -Path $tmp
Complete-TestRun -Suite 'guard-git'
