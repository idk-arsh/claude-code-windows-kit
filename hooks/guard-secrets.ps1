# PreToolUse hook. Blocks Edit and Write to paths that look like secrets.
#
# Wired via .claude/settings.json under hooks.PreToolUse with matcher "Edit|Write".
# Reads the tool-call JSON on stdin, checks tool_input.file_path against
# the deny list below, and exits with code 2 when it matches. Exit 2 makes
# Claude Code send the stderr text back to the model, which then chooses a
# different action instead of retrying.
#
# The permissions.deny block in settings.example.json covers the same simple
# cases faster. This hook adds two things settings cannot: it catches
# absolute paths (settings patterns are relative to the project), and it
# logs every block for audit at $HOME\.claude\guard-secrets.log.

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$DenyPatterns = @(
    '(^|[\\/])\.env($|\.)'
    '(^|[\\/])id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$'
    '(^|[\\/])secrets?\.'
    '(^|[\\/])credentials?(\.|$)'
    '\.(pem|key|p12|pfx)$'
    '[\\/]\.ssh[\\/]'
    '[\\/]\.aws[\\/]credentials'
    '[\\/]\.git[\\/]config$'
    '[\\/]\.npmrc$'
    '[\\/]\.pypirc$'
)

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }

try {
    $data = $raw | ConvertFrom-Json
} catch {
    # Not JSON. Let Claude proceed; a broken hook should not brick a session.
    exit 0
}

$path = $data.tool_input.file_path
if (-not $path) { exit 0 }

foreach ($pattern in $DenyPatterns) {
    if ($path -match $pattern) {
        $logDir = Join-Path $HOME ".claude"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory $logDir | Out-Null }
        $ts = Get-Date -Format "o"
        $tool = $data.tool_name
        Add-Content -Path (Join-Path $logDir "guard-secrets.log") `
                    -Value "$ts $tool $path pattern=$pattern"

        $reason = "guard-secrets: refusing $tool on $path. Matched deny pattern: $pattern. Change the path or ask the user to remove the pattern from hooks/guard-secrets.ps1."
        [Console]::Error.WriteLine($reason)
        exit 2
    }
}

exit 0
