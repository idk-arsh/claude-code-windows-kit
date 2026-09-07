# Stop hook. Beeps and pops a Windows tray notification when Claude finishes a
# turn. Wired via .claude/settings.json under hooks.Stop.
#
# The beep is the reliable signal; it uses [Console]::Beep which works on
# every Windows shell and every PowerShell version. The tray balloon is a
# best-effort second signal via System.Windows.Forms; if the assembly is
# missing (rare on Windows) or the session is headless, the balloon is
# skipped silently and the beep still fires.
#
# Reads Claude's Stop-event JSON on stdin, but only to pull the current
# working directory for the notification title. Never modifies the response.

#Requires -Version 5.1
$ErrorActionPreference = "SilentlyContinue"

# Beep first. This is the part that must not fail.
[Console]::Beep(880, 180)
[Console]::Beep(660, 180)

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

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $icon = New-Object System.Windows.Forms.NotifyIcon
    $icon.Icon = [System.Drawing.SystemIcons]::Information
    $icon.BalloonTipTitle = "$project"
    $icon.BalloonTipText = "Claude finished a turn."
    $icon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $icon.Visible = $true
    $icon.ShowBalloonTip(3000)

    Start-Sleep -Milliseconds 3200
    $icon.Dispose()
} catch { }

exit 0
