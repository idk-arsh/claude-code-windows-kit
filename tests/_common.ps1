# Shared helpers for the test scripts in this folder. Dot-source it:
#
#   . (Join-Path $PSScriptRoot '_common.ps1')
#
# Plain PowerShell, no Pester. Runs on Windows PowerShell 5.1 and PowerShell 7.
# Every hook under test is launched the way Claude Code launches it: a fresh
# shell process with -NoProfile -ExecutionPolicy Bypass -File, the payload on
# stdin, exit code and both output streams captured. System.Diagnostics.Process
# is used instead of a pipeline so that stderr from the child never turns
# into a terminating error under $ErrorActionPreference = "Stop" on 5.1.

$script:TestPassed = 0
$script:TestFailed = 0
$script:TestSkipped = 0

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Initialize-TestTempDir {
    param([string]$Root = '', [string]$Prefix = 'ccwk')
    $base = if ($Root) { $Root } else { [System.IO.Path]::GetTempPath() }
    $dir = Join-Path $base ($Prefix + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return (Resolve-Path $dir).Path
}

function Clear-TestTempDir {
    # A detached child (notify's balloon process, a killed formatter's
    # orphan) can hold the directory for a few seconds, so retry.
    param([string]$Path)
    if (-not $Path) { return }
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    Write-Host "  (could not remove $Path)"
}

function ConvertTo-CommandLineArgument {
    param([string[]]$Arguments)
    $parts = foreach ($a in $Arguments) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }
    return ($parts -join ' ')
}

function Invoke-ProcessWithInput {
    # Starts $FileName with a raw argument string, feeds $StandardInput (UTF-8)
    # on stdin, and returns ExitCode, StdOut, StdErr, TimedOut and ElapsedMs.
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [string]$Arguments = '',
        [AllowNull()][string]$StandardInput = $null,
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = '',
        [int]$TimeoutMs = 60000
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) {
            $psi.EnvironmentVariables.Remove($key)
        } else {
            $psi.EnvironmentVariables[$key] = [string]$Environment[$key]
        }
    }

    # .NET Framework builds Process.StandardInput from Console.InputEncoding
    # and writes that encoding's preamble the moment the process starts. In a
    # UTF-8 console that is a BOM in front of the payload, which Claude Code
    # never sends. Swap in a preamble-free UTF-8 before starting the child.
    if ($PSVersionTable.PSVersion.Major -le 5) {
        try {
            if ([Console]::InputEncoding.GetPreamble().Length -gt 0) {
                [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
            }
        } catch { Write-Host "  (could not change the console input encoding)" }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()
    if ($null -ne $StandardInput) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($StandardInput)
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.BaseStream.Flush()
    }
    $p.StandardInput.Close()

    $timedOut = $false
    if (-not $p.WaitForExit($TimeoutMs)) {
        $timedOut = $true
        try { $p.Kill() } catch { Write-Host "  (could not kill pid $($p.Id))" }
    }
    $p.WaitForExit()
    $sw.Stop()
    return [pscustomobject]@{
        ExitCode  = $p.ExitCode
        StdOut    = $stdoutTask.Result
        StdErr    = $stderrTask.Result
        TimedOut  = $timedOut
        ElapsedMs = $sw.ElapsedMilliseconds
    }
}

function Invoke-PowerShellFile {
    # Runs "<Shell> -NoProfile -ExecutionPolicy Bypass -File <File> <ArgumentList>".
    param(
        [string]$Shell = 'powershell.exe',
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$ArgumentList = @(),
        [AllowNull()][string]$StandardInput = $null,
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = '',
        [int]$TimeoutMs = 60000
    )
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-CommandLineArgument (@($File) + $ArgumentList))
    return Invoke-ProcessWithInput -FileName $Shell -Arguments $arguments -StandardInput $StandardInput -Environment $Environment -WorkingDirectory $WorkingDirectory -TimeoutMs $TimeoutMs
}

function Invoke-Hook {
    param(
        [string]$Shell = 'powershell.exe',
        [Parameter(Mandatory = $true)][string]$HookPath,
        [AllowNull()][string]$Payload = $null,
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = '',
        [int]$TimeoutMs = 60000
    )
    return Invoke-PowerShellFile -Shell $Shell -File $HookPath -StandardInput $Payload -Environment $Environment -WorkingDirectory $WorkingDirectory -TimeoutMs $TimeoutMs
}

function Get-GitBashExe {
    # Finds Git Bash the way install.ps1 does. Returns a path or $null.
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:CLAUDE_CODE_GIT_BASH_PATH) { $candidates.Add($env:CLAUDE_CODE_GIT_BASH_PATH) }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) { $candidates.Add((Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'bin\bash.exe')) }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if ($root) { $candidates.Add((Join-Path $root 'Git\bin\bash.exe')) }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function ConvertTo-HookPayload {
    # Builds the JSON Claude Code sends a hook. $ToolInput is a hashtable.
    param(
        [string]$ToolName = 'Bash',
        [hashtable]$ToolInput = @{},
        [string]$Cwd = '',
        [string]$EventName = 'PreToolUse'
    )
    $payload = [ordered]@{
        session_id      = 'kit-tests'
        transcript_path = ''
        cwd             = $Cwd
        hook_event_name = $EventName
        tool_name       = $ToolName
        tool_input      = $ToolInput
    }
    return ($payload | ConvertTo-Json -Compress -Depth 6)
}

function Write-TestResult {
    param([bool]$Passed, [string]$Name, [string]$Detail = '')
    if ($Passed) {
        $script:TestPassed++
        Write-Host ("  ok    {0}" -f $Name)
    } else {
        $script:TestFailed++
        Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail)
    }
}

function Assert-ExitCode {
    param([string]$Name, [int]$Expected, $Result)
    $firstErr = ''
    if ($Result.StdErr) { $firstErr = ($Result.StdErr -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1) }
    $detail = "exit={0} want={1} timedOut={2} stderr={3}" -f $Result.ExitCode, $Expected, $Result.TimedOut, $firstErr
    Write-TestResult -Passed (($Result.ExitCode -eq $Expected) -and -not $Result.TimedOut) -Name $Name -Detail $detail
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    Write-TestResult -Passed $Condition -Name $Name -Detail $Detail
}

function Write-TestSkip {
    param([string]$Name, [string]$Reason)
    $script:TestSkipped++
    Write-Host ("  skip  {0}  ({1})" -f $Name, $Reason)
}

function Complete-TestRun {
    param([string]$Suite)
    Write-Host ""
    Write-Host ("{0}: {1} passed, {2} failed, {3} skipped" -f $Suite, $script:TestPassed, $script:TestFailed, $script:TestSkipped)
    if ($script:TestFailed -gt 0) { exit 1 }
}
