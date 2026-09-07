# Smoke tests for hooks/format-on-edit.ps1. Plain PowerShell, no Pester.
#
#   powershell -ExecutionPolicy Bypass -File tests\format-on-edit.tests.ps1
#
# The hook must always exit 0 and finish quickly. Cases that need a real
# formatter run when one is available and are reported as skipped otherwise:
#   ruff      found on PATH (CI: pip install ruff)
#   prettier  a directory with node_modules\prettier, passed as
#             -PrettierProject or the KIT_TEST_PRETTIER_PROJECT variable
# The timeout and failure paths use throwaway .cmd shims, so they always run.

[CmdletBinding()]
param(
    [string]$Shell = 'powershell.exe',
    [string]$TempRoot = '',
    [string]$PrettierProject = $env:KIT_TEST_PRETTIER_PROJECT
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$hook = Join-Path (Get-RepoRoot) 'hooks\format-on-edit.ps1'
$tmp = Initialize-TestTempDir -Root $TempRoot -Prefix 'ccwk-format'
$fakeHome = Join-Path $tmp 'home'
$proj = Join-Path $tmp 'proj'
New-Item -ItemType Directory -Path $fakeHome, $proj -Force | Out-Null
$hookEnv = @{ USERPROFILE = $fakeHome; HOME = $fakeHome; HOMEDRIVE = (Split-Path -Qualifier $fakeHome); HOMEPATH = (Split-Path -NoQualifier $fakeHome) }
$system32 = Join-Path $env:SystemRoot 'System32'

function Invoke-Format {
    param(
        [string]$Name,
        [string]$FilePath,
        [string]$Tool = 'Edit',
        [hashtable]$ExtraEnv = @{},
        [string]$Cwd = $proj,
        [int]$MaxMs = 20000
    )
    $childEnv = $hookEnv.Clone()
    foreach ($k in $ExtraEnv.Keys) { $childEnv[$k] = $ExtraEnv[$k] }
    $payload = ConvertTo-HookPayload -ToolName $Tool -ToolInput @{ file_path = $FilePath } -Cwd $Cwd -EventName 'PostToolUse'
    $result = Invoke-Hook -Shell $Shell -HookPath $hook -Payload $payload -Environment $childEnv -WorkingDirectory $proj -TimeoutMs 60000
    Assert-ExitCode -Name $Name -Expected 0 -Result $result
    Assert-True -Name "$Name finished in under $MaxMs ms" -Condition ($result.ElapsedMs -lt $MaxMs) -Detail "took $($result.ElapsedMs) ms"
    return $result
}

function Get-FormatLogText {
    $text = ''
    foreach ($candidate in @((Join-Path $fakeHome '.claude\format-on-edit.log'), (Join-Path $HOME '.claude\format-on-edit.log'))) {
        if (Test-Path -LiteralPath $candidate) { $text += (Get-Content -LiteralPath $candidate -Raw) }
    }
    return $text
}

function Assert-Logged {
    param([string]$Name, [string]$FilePath, [string]$Pattern)
    $text = Get-FormatLogText
    $lines = @($text -split "`r?`n" | Where-Object { $_ -match [regex]::Escape($FilePath) })
    $hit = @($lines | Where-Object { $_ -match $Pattern })
    Assert-True -Name $Name -Condition ($hit.Count -ge 1) -Detail ("lines for file: " + ($lines -join ' || '))
}

Write-Host "format-on-edit.ps1 under $Shell"
Write-Host ""
Write-Host "files with no formatter"
$txt = Join-Path $proj 'notes.txt'
Set-Content -Path $txt -Value "  messy   text  " -NoNewline
Invoke-Format -Name '.txt exits 0' -FilePath $txt | Out-Null
Assert-True -Name '.txt left untouched' -Condition ((Get-Content -Raw $txt) -eq "  messy   text  ")
Assert-Logged -Name '.txt skip logged with reason' -FilePath $txt -Pattern "skip: no formatter found for '\.txt'"

$ps1 = Join-Path $proj 'script.ps1'
Set-Content -Path $ps1 -Value 'Write-Host   "x"' -NoNewline
Invoke-Format -Name '.ps1 exits 0' -FilePath $ps1 -Tool 'Write' | Out-Null
Assert-True -Name '.ps1 left untouched' -Condition ((Get-Content -Raw $ps1) -eq 'Write-Host   "x"')
Assert-Logged -Name '.ps1 skip logged' -FilePath $ps1 -Pattern 'skip: no stock formatter for \.ps1'

Invoke-Format -Name 'missing file exits 0' -FilePath (Join-Path $proj 'does-not-exist.py') | Out-Null
Assert-Logged -Name 'missing file logged' -FilePath 'does-not-exist.py' -Pattern 'skip: file not found'

Set-Content -Path (Join-Path $proj 'relative.txt') -Value 'x' -NoNewline
Invoke-Format -Name 'relative path resolved against cwd' -FilePath 'relative.txt' -Cwd $proj | Out-Null
Assert-Logged -Name 'relative path logged as full path' -FilePath (Join-Path $proj 'relative.txt') -Pattern 'skip: no formatter'

$nm = Join-Path $proj 'node_modules\dep'
New-Item -ItemType Directory -Path $nm -Force | Out-Null
$depFile = Join-Path $nm 'index.js'
Set-Content -Path $depFile -Value 'const   a=1' -NoNewline
Invoke-Format -Name 'file under node_modules exits 0' -FilePath $depFile | Out-Null
Assert-True -Name 'file under node_modules untouched' -Condition ((Get-Content -Raw $depFile) -eq 'const   a=1')
Assert-Logged -Name 'node_modules skip logged' -FilePath $depFile -Pattern 'skip: dependency or build directory'

Write-Host ""
Write-Host "payload handling"
foreach ($case in @(
        @{ Name = 'malformed JSON'; Payload = '{"tool_name": "Edit", "tool_input": {' },
        @{ Name = 'empty stdin'; Payload = '' },
        @{ Name = 'no file_path'; Payload = '{"tool_name":"Edit","tool_input":{"old_string":"a"}}' },
        @{ Name = 'tool_input null'; Payload = '{"tool_name":"Edit","tool_input":null}' },
        @{ Name = 'file_path is a number'; Payload = '{"tool_name":"Edit","tool_input":{"file_path":42}}' }
    )) {
    $r = Invoke-Hook -Shell $Shell -HookPath $hook -Payload $case.Payload -Environment $hookEnv -WorkingDirectory $proj
    Assert-ExitCode -Name $case.Name -Expected 0 -Result $r
}

Write-Host ""
Write-Host "python via ruff"
$messyPy = "import os,sys`ndef  f( a,b ):`n    return a+b`nx = {  'a':1,'b':2 }`nprint( f(1,2) )`n"
$ruffOnPath = Get-Command ruff -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ruffOnPath) {
    $py = Join-Path $proj 'messy.py'
    Set-Content -Path $py -Value $messyPy -NoNewline
    Invoke-Format -Name 'ruff from PATH runs' -FilePath $py | Out-Null
    $after = Get-Content -Raw $py
    Assert-True -Name 'ruff changed the file' -Condition ($after -ne $messyPy)
    Assert-True -Name 'ruff output has normalised spacing' -Condition ($after -match 'def f\(a, b\):' -and $after -match 'print\(f\(1, 2\)\)')
    & $ruffOnPath.Source format --check $py | Out-Null
    Assert-True -Name 'ruff format --check passes afterwards' -Condition ($LASTEXITCODE -eq 0)
    Assert-Logged -Name 'ruff run logged with exit 0' -FilePath $py -Pattern 'ruff \(.*\) exit=0'

    # Project-local ruff: copy the binary into a fake .venv and hide PATH.
    $proj2 = Join-Path $tmp 'proj2\src\pkg'
    New-Item -ItemType Directory -Path $proj2 -Force | Out-Null
    $venvScripts = Join-Path $tmp 'proj2\.venv\Scripts'
    New-Item -ItemType Directory -Path $venvScripts -Force | Out-Null
    Copy-Item $ruffOnPath.Source (Join-Path $venvScripts 'ruff.exe')
    $py2 = Join-Path $proj2 'module.py'
    Set-Content -Path $py2 -Value $messyPy -NoNewline
    Invoke-Format -Name 'ruff from the project .venv, nothing on PATH' -FilePath $py2 -ExtraEnv @{ PATH = $system32 } | Out-Null
    Assert-True -Name 'project ruff changed the file' -Condition ((Get-Content -Raw $py2) -ne $messyPy)
    Assert-Logged -Name 'project ruff path logged' -FilePath $py2 -Pattern '\\\.venv\\Scripts\\ruff\.exe\) exit=0'
} else {
    Write-TestSkip 'ruff cases' 'ruff not on PATH'
}

Write-Host ""
Write-Host "javascript via prettier"
$prettierCli = $null
if ($PrettierProject) {
    foreach ($rel in @('node_modules\prettier\bin\prettier.cjs', 'node_modules\prettier\bin-prettier.js')) {
        $candidate = Join-Path $PrettierProject $rel
        if (Test-Path -LiteralPath $candidate) { $prettierCli = $candidate }
    }
}
if ($prettierCli -and (Get-Command node -CommandType Application -ErrorAction SilentlyContinue)) {
    $js = Join-Path $PrettierProject ('ccwk-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.js')
    $messyJs = "const   a = {b:1,c:2}`nfunction f( x ){return x+1}`n"
    Set-Content -Path $js -Value $messyJs -NoNewline
    try {
        Invoke-Format -Name 'prettier from node_modules runs' -FilePath $js -Cwd $PrettierProject | Out-Null
        $afterJs = Get-Content -Raw $js
        Assert-True -Name 'prettier changed the file' -Condition ($afterJs -ne $messyJs)
        Assert-True -Name 'prettier output is formatted' -Condition ($afterJs -match 'const a = \{ b: 1, c: 2 \};' -and $afterJs -match 'function f\(x\) \{')
        Assert-Logged -Name 'prettier run logged with exit 0' -FilePath $js -Pattern 'prettier \(.*\) exit=0'
    } finally {
        Remove-Item -LiteralPath $js -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-TestSkip 'prettier cases' 'no prettier project given (set KIT_TEST_PRETTIER_PROJECT) or node missing'
}

Write-Host ""
Write-Host "timeout and failure paths (fake formatters)"
$fakeBin = Join-Path $tmp 'fakebin'
New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
Set-Content -Path (Join-Path $fakeBin 'gofmt.cmd') -Value "@echo off`r`nping -n 30 127.0.0.1 > nul`r`n"
Set-Content -Path (Join-Path $fakeBin 'rustfmt.cmd') -Value "@echo off`r`necho boom 1>&2`r`nexit /b 3`r`n"
$fakePath = "$fakeBin;$system32"

$go = Join-Path $proj 'main.go'
Set-Content -Path $go -Value "package main`n" -NoNewline
$slow = Invoke-Format -Name 'slow formatter is killed, hook still exits 0' -FilePath $go -ExtraEnv @{ PATH = $fakePath } -MaxMs 16000
Assert-True -Name 'slow formatter took at least the 8 s budget' -Condition ($slow.ElapsedMs -ge 7500) -Detail "took $($slow.ElapsedMs) ms"
Assert-Logged -Name 'timeout logged' -FilePath $go -Pattern 'gofmt \(.*\) timed out after 8000ms and was killed'

$rs = Join-Path $proj 'lib.rs'
Set-Content -Path $rs -Value "fn main() {}`n" -NoNewline
Invoke-Format -Name 'failing formatter, hook still exits 0' -FilePath $rs -ExtraEnv @{ PATH = $fakePath } | Out-Null
Assert-Logged -Name 'failure exit code and stderr logged' -FilePath $rs -Pattern 'rustfmt \(.*\) exit=3 .*stderr: boom'

Clear-TestTempDir -Path $tmp
Complete-TestRun -Suite 'format-on-edit'
