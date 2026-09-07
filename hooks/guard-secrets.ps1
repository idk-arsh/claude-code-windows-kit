# PreToolUse hook. Blocks Read, Edit and Write on paths that look like secrets.
#
# Wired via .claude/settings.json under hooks.PreToolUse with matcher
# "Read|Edit|Write". Reads the tool-call JSON on stdin, checks
# tool_input.file_path against the deny list below, and exits with code 2
# when it matches. Exit 2 makes Claude Code block the call and send the
# stderr text back to the model, which then chooses a different action.
#
# The permissions.deny block in settings.example.json covers the same paths
# without a shell round trip, and Claude Code applies those rules to Grep,
# Glob and to `cat`-style Bash commands as well. What this hook adds is an
# audit line for every blocked attempt at $HOME\.claude\guard-secrets.log,
# and one place to keep patterns that are easier to write as regex.
#
# Anything that goes wrong in here (bad JSON, missing field) lets the call
# through. A failed logging write does not: the block still fires.

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

# Checked first. A match here lets the call through.
$AllowPatterns = @(
    '(^|[\\/])\.env\.(example|sample|template)$'
)

$DenyPatterns = @(
    '(^|[\\/])\.env($|\.)'
    '(^|[\\/])id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$'
    '(^|[\\/])secrets?[\\/.]'
    '(^|[\\/])credentials?(\.|$)'
    '\.(pem|key|p12|pfx)$'
    '(^|[\\/])\.ssh[\\/]'
    '(^|[\\/])\.aws[\\/]credentials$'
    '(^|[\\/])\.git[\\/]config$'
    '(^|[\\/])\.npmrc$'
    '(^|[\\/])\.pypirc$'
)

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }

try {
    $data = $raw | ConvertFrom-Json
} catch {
    # Not JSON. Let Claude proceed; a broken hook should not brick a session.
    exit 0
}

$path = [string]$data.tool_input.file_path
if (-not $path) { exit 0 }

foreach ($pattern in $AllowPatterns) {
    if ($path -match $pattern) { exit 0 }
}

foreach ($pattern in $DenyPatterns) {
    if ($path -match $pattern) {
        $tool = $data.tool_name

        try {
            $logDir = Join-Path $HOME ".claude"
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory $logDir | Out-Null }
            $ts = Get-Date -Format "o"
            Add-Content -Path (Join-Path $logDir "guard-secrets.log") `
                        -Value "$ts $tool $path pattern=$pattern"
        } catch {
            # Logging is best effort. Never let a log failure turn into an allow.
        }

        $reason = "guard-secrets: refusing $tool on $path. Matched deny pattern: $pattern. Change the path or ask the user to remove the pattern from hooks/guard-secrets.ps1."
        [Console]::Error.WriteLine($reason)
        exit 2
    }
}

exit 0
