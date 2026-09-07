# Stop hook. Beeps and pops a Windows tray notification when Claude finishes a
# turn. Wired via .claude/settings.json under hooks.Stop.
#
# The beep is the reliable signal; it uses [Console]::Beep which works on
# every Windows shell and every PowerShell version. The tray balloon is a
# best-effort second signal via System.Windows.Forms; if the assembly is
# missing (rare on Windows) or the session is headless, the balloon is
# skipped silently and the beep still fires.
#
# Claude Code waits for Stop hooks to exit before it hands the prompt back,
# so this script must return fast. The balloon needs its owning process to
# stay alive for a few seconds or Windows takes it down again, so the balloon
# runs in a detached hidden PowerShell and this script exits right away.
#
# Reads Claude's Stop-event JSON on stdin, but only to pull the current
# working directory for the notification title. Never modifies the response.

#Requires -Version 5.1
$ErrorActionPreference = "SilentlyContinue"

# Beep first. This is the part that must not fail.
try {
    [Console]::Beep(880, 180)
    [Console]::Beep(660, 180)
} catch { }

$raw = [Console]::In.ReadToEnd()
$project = "Claude Code"
if ($raw) {
    try {
        $data = $raw | ConvertFrom-Json
        if ($data.cwd) {
            $project = Split-Path -Leaf $data.cwd
        }
    } catch { }
}

# Single quotes inside the title would break the child script below.
$title = $project -replace "'", "''"

$balloon = @"
`$ErrorActionPreference = 'SilentlyContinue'
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    `$icon = New-Object System.Windows.Forms.NotifyIcon
    `$icon.Icon = [System.Drawing.SystemIcons]::Information
    `$icon.BalloonTipTitle = '$title'
    `$icon.BalloonTipText = 'Claude finished a turn.'
    `$icon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    `$icon.Visible = `$true
    `$icon.ShowBalloonTip(3000)
    Start-Sleep -Milliseconds 3200
    `$icon.Dispose()
} catch { }
"@

try {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($balloon))
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-EncodedCommand", $encoded
    ) | Out-Null
} catch { }

exit 0
