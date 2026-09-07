# PostToolUse hook. Runs the project's formatter on the file Claude just
# wrote, so formatting drift never shows up in the diff.
#
# Wired via .claude/settings.json under hooks.PostToolUse with matcher
# "Edit|Write". Reads the tool-call JSON on stdin, takes tool_input.file_path
# (Claude Code sends it with backslashes on Windows, absolute or relative to
# cwd), picks a formatter by extension, and runs it on that one file:
#
#   .py                                  ruff format, else black
#   .js .jsx .ts .tsx .json .css .md     prettier --write
#   .go                                  gofmt -w
#   .rs                                  rustfmt --edition 2021
#   .ps1                                 skipped, there is no stock formatter
#
# Where the formatter comes from, in order:
#   ruff / black    <project>\.venv\Scripts\ or venv\Scripts\ (walking up from
#                   the file), then PATH
#   prettier        <project>\node_modules\prettier run through node (walking
#                   up from the file), then node_modules\.bin\prettier.cmd,
#                   then PATH
#   gofmt / rustfmt PATH
#
# No formatter found: nothing happens. Files under node_modules, .venv, venv,
# .git, dist, build, vendor or __pycache__ are left alone. The child process
# gets 8 seconds and is killed after that. This hook always exits 0: a
# PostToolUse hook cannot undo the edit, and a formatter failure is not a
# reason to interrupt the model. One line per run goes to
# $HOME\.claude\format-on-edit.log, including skips and the reason, so
# "why was my file not formatted" has an answer.

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$ChildTimeoutMs = 8000
$SkipDirPattern = '[\\/](node_modules|\.venv|venv|\.git|dist|build|vendor|__pycache__)[\\/]'

function Write-FormatLog {
    param([string]$Line)
    try {
        $logDir = Join-Path $HOME ".claude"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory $logDir | Out-Null }
        Add-Content -Path (Join-Path $logDir "format-on-edit.log") -Value ((Get-Date -Format "o") + " " + $Line)
    } catch {
        # Logging is best effort.
    }
}

function Find-UpTree {
    # Walks from $StartDir toward the drive root looking for any of
    # $RelativePaths. Returns the first hit or $null.
    param([string]$StartDir, [string[]]$RelativePaths, [int]$MaxLevels = 12)
    $dir = $StartDir
    for ($level = 0; $level -lt $MaxLevels -and $dir; $level++) {
        foreach ($rel in $RelativePaths) {
            $candidate = Join-Path $dir $rel
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Get-PathCommand {
    param([string]$Name)
    $found = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    return $null
}

function ConvertTo-ArgumentString {
    param([string[]]$Arguments)
    $parts = foreach ($a in $Arguments) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }
    return ($parts -join ' ')
}

function Invoke-ChildProcess {
    # Runs a formatter with a hard timeout. .cmd and .bat shims go through
    # cmd.exe; everything else is started directly. Returns TimedOut,
    # ExitCode and the first line of stderr.
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutMs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($FilePath -match '\.(cmd|bat)$') {
        $psi.FileName = "$env:SystemRoot\System32\cmd.exe"
        $psi.Arguments = '/d /s /c "' + (ConvertTo-ArgumentString (@($FilePath) + $Arguments)) + '"'
    } else {
        $psi.FileName = $FilePath
        $psi.Arguments = ConvertTo-ArgumentString $Arguments
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutMs)) {
        try { $proc.Kill() } catch { Write-FormatLog "could not kill pid $($proc.Id)" }
        return @{ TimedOut = $true; ExitCode = -1; StdErr = '' }
    }
    $proc.WaitForExit()
    [void]$stdoutTask.Result
    $firstErr = ''
    if ($stderrTask.Result) { $firstErr = ($stderrTask.Result -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1) }
    return @{ TimedOut = $false; ExitCode = $proc.ExitCode; StdErr = $firstErr }
}

function Resolve-Formatter {
    # Returns @{ Name; File; Arguments } or $null.
    param([string]$FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $dir = Split-Path -Parent $FilePath
    switch ($ext) {
        '.py' {
            $exe = Find-UpTree -StartDir $dir -RelativePaths @('.venv\Scripts\ruff.exe', 'venv\Scripts\ruff.exe')
            if (-not $exe) { $exe = Get-PathCommand 'ruff' }
            if ($exe) { return @{ Name = 'ruff'; File = $exe; Arguments = @('format', '--quiet', $FilePath) } }
            $exe = Find-UpTree -StartDir $dir -RelativePaths @('.venv\Scripts\black.exe', 'venv\Scripts\black.exe')
            if (-not $exe) { $exe = Get-PathCommand 'black' }
            if ($exe) { return @{ Name = 'black'; File = $exe; Arguments = @('--quiet', $FilePath) } }
            return $null
        }
        { $_ -in @('.js', '.jsx', '.ts', '.tsx', '.json', '.css', '.md') } {
            $cli = Find-UpTree -StartDir $dir -RelativePaths @('node_modules\prettier\bin\prettier.cjs', 'node_modules\prettier\bin-prettier.js')
            if ($cli) {
                $node = Get-PathCommand 'node'
                if ($node) { return @{ Name = 'prettier'; File = $node; Arguments = @($cli, '--write', $FilePath) } }
            }
            $shim = Find-UpTree -StartDir $dir -RelativePaths @('node_modules\.bin\prettier.cmd')
            if (-not $shim) { $shim = Get-PathCommand 'prettier' }
            if ($shim) { return @{ Name = 'prettier'; File = $shim; Arguments = @('--write', $FilePath) } }
            return $null
        }
        '.go' {
            $exe = Get-PathCommand 'gofmt'
            if ($exe) { return @{ Name = 'gofmt'; File = $exe; Arguments = @('-w', $FilePath) } }
            return $null
        }
        '.rs' {
            $exe = Get-PathCommand 'rustfmt'
            if ($exe) { return @{ Name = 'rustfmt'; File = $exe; Arguments = @('--edition', '2021', $FilePath) } }
            return $null
        }
    }
    return $null
}

# ---- main ----

$timer = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $stdin = [Console]::OpenStandardInput()
    $buffer = New-Object System.IO.MemoryStream
    $stdin.CopyTo($buffer)
    $raw = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray()).TrimStart([char]0xFEFF)
    if (-not $raw.Trim()) { exit 0 }

    $data = $raw | ConvertFrom-Json
    $tool = [string]$data.tool_name
    $path = [string]$data.tool_input.file_path
    if (-not $path) { exit 0 }

    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $base = [string]$data.cwd
        if ($base) { $path = Join-Path $base $path }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-FormatLog "$tool $path skip: file not found"
        exit 0
    }
    $full = (Resolve-Path -LiteralPath $path).Path
    if ($full -match $SkipDirPattern) {
        Write-FormatLog "$tool $full skip: dependency or build directory"
        exit 0
    }

    $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
    if ($ext -eq '.ps1') {
        Write-FormatLog "$tool $full skip: no stock formatter for .ps1"
        exit 0
    }
    $formatter = Resolve-Formatter -FilePath $full
    if (-not $formatter) {
        Write-FormatLog "$tool $full skip: no formatter found for '$ext'"
        exit 0
    }

    $result = Invoke-ChildProcess -FilePath $formatter.File -Arguments $formatter.Arguments -WorkingDirectory (Split-Path -Parent $full) -TimeoutMs $ChildTimeoutMs
    if ($result.TimedOut) {
        Write-FormatLog "$tool $full $($formatter.Name) ($($formatter.File)) timed out after ${ChildTimeoutMs}ms and was killed"
    } else {
        $note = ''
        if ($result.ExitCode -ne 0 -and $result.StdErr) { $note = " stderr: $($result.StdErr)" }
        Write-FormatLog "$tool $full $($formatter.Name) ($($formatter.File)) exit=$($result.ExitCode) $($timer.ElapsedMilliseconds)ms$note"
    }
} catch {
    Write-FormatLog "error: $($_.Exception.Message)"
}
exit 0
