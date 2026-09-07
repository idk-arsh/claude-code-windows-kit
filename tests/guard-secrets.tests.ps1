# Test matrix for hooks/guard-secrets.ps1. Plain PowerShell, no Pester.
#
#   powershell -ExecutionPolicy Bypass -File tests\guard-secrets.tests.ps1
#   pwsh -File tests\guard-secrets.tests.ps1 -Shell pwsh
#
# Each case pipes a PreToolUse payload into the hook the way Claude Code does
# and checks the exit code: 2 means blocked, 0 means allowed. Exits 1 if any
# case fails.

[CmdletBinding()]
param(
    [string]$Shell = 'powershell.exe',
    [string]$TempRoot = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$hook = Join-Path (Get-RepoRoot) 'hooks\guard-secrets.ps1'
$tmp = Initialize-TestTempDir -Root $TempRoot -Prefix 'ccwk-guard-secrets'
$fakeHome = Join-Path $tmp 'home'
New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
$hookEnv = @{ USERPROFILE = $fakeHome; HOME = $fakeHome; HOMEDRIVE = (Split-Path -Qualifier $fakeHome); HOMEPATH = (Split-Path -NoQualifier $fakeHome) }

function Test-Secret {
    param([string]$Name, [string]$Tool, [string]$Path, [int]$Expect)
    $payload = ConvertTo-HookPayload -ToolName $Tool -ToolInput @{ file_path = $Path }
    $result = Invoke-Hook -Shell $Shell -HookPath $hook -Payload $payload -Environment $hookEnv -WorkingDirectory $tmp
    Assert-ExitCode -Name $Name -Expected $Expect -Result $result
    return $result
}

function Test-RawPayload {
    param([string]$Name, [AllowNull()][string]$Payload, [int]$Expect)
    $result = Invoke-Hook -Shell $Shell -HookPath $hook -Payload $Payload -Environment $hookEnv -WorkingDirectory $tmp
    Assert-ExitCode -Name $Name -Expected $Expect -Result $result
}

Write-Host "guard-secrets.ps1 under $Shell"
Write-Host ""
Write-Host "dotenv files"
$blocked = Test-Secret 'Read .env' 'Read' '.env' 2
Test-Secret 'Edit .env.local' 'Edit' '.env.local' 2 | Out-Null
Test-Secret 'Edit nested config/.env.production' 'Edit' 'config/.env.production' 2 | Out-Null
Test-Secret 'Read /c/Users/x/proj/.env (msys path)' 'Read' '/c/Users/x/proj/.env' 2 | Out-Null
Test-Secret 'Edit path with a space then .env' 'Edit' 'C:\Users\Some Name\proj\.env' 2 | Out-Null
Test-Secret 'Edit .ENV upper case' 'Edit' '.ENV' 2 | Out-Null
Test-Secret 'Read .env.example is allowed' 'Read' '.env.example' 0 | Out-Null
Test-Secret 'Edit config\.env.sample is allowed' 'Edit' 'config\.env.sample' 0 | Out-Null
Test-Secret 'Read .envrc is not dotenv' 'Read' '.envrc' 0 | Out-Null
Test-Secret 'Read environment.py' 'Read' 'src/environment.py' 0 | Out-Null
Test-Secret 'Read dotenv.py' 'Read' 'lib/dotenv.py' 0 | Out-Null

Write-Host ""
Write-Host "keys, credentials, rc files"
Test-Secret 'Read absolute .ssh\id_rsa' 'Read' 'C:\Users\x\.ssh\id_rsa' 2 | Out-Null
Test-Secret 'Edit absolute .ssh\known_hosts' 'Edit' 'C:\Users\x\.ssh\known_hosts' 2 | Out-Null
Test-Secret 'Edit relative .ssh/known_hosts' 'Edit' '.ssh/known_hosts' 2 | Out-Null
Test-Secret 'Edit id_ed25519.pub' 'Edit' 'id_ed25519.pub' 2 | Out-Null
Test-Secret 'Edit certs/server.key' 'Edit' 'certs/server.key' 2 | Out-Null
Test-Secret 'Edit src/keyboard.py is not a .key' 'Edit' 'src/keyboard.py' 0 | Out-Null
Test-Secret 'Edit app/credentials.py' 'Edit' 'app/credentials.py' 2 | Out-Null
Test-Secret 'Edit relative .aws/credentials' 'Edit' '.aws/credentials' 2 | Out-Null
Test-Secret 'Read absolute .aws\credentials' 'Read' 'C:\Users\x\.aws\credentials' 2 | Out-Null
Test-Secret 'Write secrets/config.json' 'Write' 'secrets/config.json' 2 | Out-Null
Test-Secret 'Write absolute secrets\ folder' 'Write' 'C:\proj\secrets\db.json' 2 | Out-Null
Test-Secret 'Edit relative .npmrc' 'Edit' '.npmrc' 2 | Out-Null
Test-Secret 'Edit relative .pypirc' 'Edit' '.pypirc' 2 | Out-Null
Test-Secret 'Edit relative .git/config' 'Edit' '.git/config' 2 | Out-Null
Test-Secret 'Read src/main.py' 'Read' 'src/main.py' 0 | Out-Null

Write-Host ""
Write-Host "out of scope for this hook"
Test-RawPayload 'Bash cat .env (no file_path)' '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}' 0
Test-RawPayload 'Bash type id_rsa (no file_path)' '{"tool_name":"Bash","tool_input":{"command":"type C:\\Users\\x\\.ssh\\id_rsa"}}' 0
Test-RawPayload 'Grep with path .env' '{"tool_name":"Grep","tool_input":{"pattern":"KEY","path":".env"}}' 0
Test-RawPayload 'Glob with path .ssh' '{"tool_name":"Glob","tool_input":{"pattern":"*","path":"C:\\Users\\x\\.ssh"}}' 0

Write-Host ""
Write-Host "payload handling"
Test-RawPayload 'unknown tool, no tool_input' '{"tool_name":"Task"}' 0
Test-RawPayload 'tool_input null' '{"tool_name":"Edit","tool_input":null}' 0
Test-RawPayload 'file_path is a number' '{"tool_name":"Edit","tool_input":{"file_path":42}}' 0
Test-RawPayload 'empty stdin' '' 0
Test-RawPayload 'closed stdin' $null 0
Test-RawPayload 'malformed JSON' '{"tool_name": "Edit", "tool_input": {' 0

Write-Host ""
Write-Host "block output"
Assert-True -Name 'stderr names the pattern' -Condition ($blocked.StdErr -match 'guard-secrets: refusing Read on \.env\. Matched deny pattern') -Detail $blocked.StdErr
$marker = 'kit-marker-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
Test-Secret 'blocked path for the log check' 'Read' "C:\proj\$marker\.env" 2 | Out-Null
$logged = $false
foreach ($candidate in @((Join-Path $fakeHome '.claude\guard-secrets.log'), (Join-Path $HOME '.claude\guard-secrets.log'))) {
    if ((Test-Path -LiteralPath $candidate) -and ((Get-Content -LiteralPath $candidate -Raw) -match [regex]::Escape($marker))) { $logged = $true }
}
Assert-True -Name 'block written to guard-secrets.log' -Condition $logged

Clear-TestTempDir -Path $tmp
Complete-TestRun -Suite 'guard-secrets'
