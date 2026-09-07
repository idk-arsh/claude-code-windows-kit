# Runs PSScriptAnalyzer over every .ps1 in the repo with the ruleset in
# PSScriptAnalyzerSettings.psd1 and exits 1 on any finding.
#
#   powershell -ExecutionPolicy Bypass -File tests\lint.ps1
#   Install-Module PSScriptAnalyzer -Scope CurrentUser   # once, if missing

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Host "PSScriptAnalyzer is not installed. Run: Install-Module PSScriptAnalyzer -Scope CurrentUser"
    exit 1
}
Import-Module PSScriptAnalyzer

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$files = @(Get-ChildItem -Path $root -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' })
Write-Host ("PSScriptAnalyzer {0} on {1} files" -f (Get-Module PSScriptAnalyzer).Version, $files.Count)

$findings = @()
foreach ($file in $files) {
    $findings += @(Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settings)
}

foreach ($f in $findings) {
    Write-Host ("  {0,-11} {1,-45} {2}:{3}  {4}" -f $f.Severity, $f.RuleName, $f.ScriptName, $f.Line, $f.Message)
}
$errors = @($findings | Where-Object { $_.Severity -eq 'Error' }).Count
$warnings = @($findings | Where-Object { $_.Severity -eq 'Warning' }).Count
Write-Host ("{0} errors, {1} warnings" -f $errors, $warnings)
if ($findings.Count -gt 0) { exit 1 }
Write-Host "clean"
exit 0
