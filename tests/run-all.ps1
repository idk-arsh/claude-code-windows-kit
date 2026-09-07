# Runs every test suite in this folder, each in its own process, and exits 1
# if any of them failed.
#
#   powershell -ExecutionPolicy Bypass -File tests\run-all.ps1
#   pwsh -File tests\run-all.ps1 -Shell pwsh
#
# -Shell picks the PowerShell that runs both the suites and the hooks under
# test (powershell.exe or pwsh). -PrettierProject points at a directory with
# node_modules\prettier for the formatter test; without it that case is
# skipped.

[CmdletBinding()]
param(
    [string]$Shell = 'powershell.exe',
    [string]$TempRoot = '',
    [string]$PrettierProject = $env:KIT_TEST_PRETTIER_PROJECT
)

$ErrorActionPreference = 'Stop'
$suites = @(
    'settings.tests.ps1',
    'guard-secrets.tests.ps1',
    'guard-git.tests.ps1',
    'format-on-edit.tests.ps1',
    'install.tests.ps1'
)
$failed = @()
foreach ($suite in $suites) {
    $path = Join-Path $PSScriptRoot $suite
    Write-Host ""
    Write-Host "=== $suite"
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path, '-Shell', $Shell)
    if ($TempRoot) { $argList += @('-TempRoot', $TempRoot) }
    if ($suite -eq 'format-on-edit.tests.ps1' -and $PrettierProject) { $argList += @('-PrettierProject', $PrettierProject) }
    & $Shell @argList
    if ($LASTEXITCODE -ne 0) { $failed += $suite }
}

Write-Host ""
if ($failed.Count -gt 0) {
    Write-Host "FAILED: $($failed -join ', ')"
    exit 1
}
Write-Host "all suites passed under $Shell"
exit 0
