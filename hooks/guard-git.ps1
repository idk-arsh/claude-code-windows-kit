# PreToolUse hook. Blocks the shell commands that cost the most when an
# agent runs them by accident.
#
# Wired via .claude/settings.json under hooks.PreToolUse with matcher
# "Bash|PowerShell". Reads the tool-call JSON on stdin, takes
# tool_input.command, splits it into the pieces a shell would run (&&, ||,
# ;, |, &, newlines), tokenises each piece with quote handling, and checks
# every piece against the rules below. A match writes a deny decision as
# JSON on stdout, the reason on stderr, and exits 2.
#
# Why both JSON and exit 2: the docs prefer a JSON permissionDecision on
# stdout, and Claude Code reads that JSON on every exit code. Exit 2 is the
# one signal JSON cannot override, so if the JSON is ever not parsed the
# block still holds. A guard should fail closed.
#
# Rules:
#   git push       --force, -f, or a +refspec to main or master. Also when
#                  no branch is named and the current branch (git
#                  symbolic-ref, run in the payload's cwd, or in the
#                  directory a leading cd or git -C points at) is main or
#                  master. If the current branch cannot be read, any force
#                  push without a branch is blocked. --force-with-lease and
#                  --force-if-includes count as force, so they pass to a
#                  feature branch and are refused on main or master.
#                  --all or --mirror with a force flag is blocked. Deleting
#                  main or master (--delete, -d, :main) is blocked.
#   git reset      --hard together with a remote ref (origin/x, @{u},
#                  refs/remotes/..., FETCH_HEAD).
#   git checkout   -- . (or ., ./, :/, *) on the whole tree.
#   git restore    . (or ./, :/, *) unless it is --staged only.
#   git clean      with -f or --force, unless -n / --dry-run is also given.
#   git branch     -D, or -d plus --force, on main or master.
#   rm             recursive (-r, -R, --recursive, any cluster with r) on /,
#                  ~, $HOME, ., .., *, ./*, a drive root (C:\, /c, /mnt/c)
#                  or with --no-preserve-root.
#   Remove-Item    (and ri, del, erase, rd, rmdir) with -Recurse on the same
#                  set of targets, plus $env:USERPROFILE.
#   bash -c, sh -c, cmd /c, powershell -Command, pwsh -Command and
#                  -EncodedCommand: the inner command is checked with the
#                  same rules, three levels deep.
#
# Line continuations (backslash-newline in bash, backtick-newline in
# PowerShell) are joined before parsing, so splitting a flag onto its own
# line does not get past the check.
#
# Everything else passes. Bad JSON or a missing command lets the call
# through: a broken hook should not brick a session. Every block is logged
# to $HOME\.claude\guard-git.log; a failed log write does not turn a block
# into an allow.
#
# This is a guardrail, not a sandbox. Shell expansion tricks ($IFS, eval,
# variables that hold the command) are not chased.

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$DefaultBranches = @('main', 'master')
$ShellWrappers = @('bash', 'sh', 'zsh', 'dash', 'cmd', 'powershell', 'pwsh')
$MaxDepth = 3

function Split-CommandSegment {
    # Split on &&, ||, ;, |, & and newlines, but not inside quotes.
    param([string]$Command)
    $segments = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $quote = [char]0
    $i = 0
    $n = $Command.Length
    while ($i -lt $n) {
        $c = $Command[$i]
        if ($quote -ne [char]0) {
            [void]$sb.Append($c)
            if ($c -eq $quote) { $quote = [char]0 }
            $i++
            continue
        }
        if ($c -eq '"' -or $c -eq "'") {
            $quote = $c
            [void]$sb.Append($c)
            $i++
            continue
        }
        if ($c -eq '&' -or $c -eq '|' -or $c -eq ';' -or $c -eq "`n" -or $c -eq "`r") {
            $segments.Add($sb.ToString())
            [void]$sb.Clear()
            if (($c -eq '&' -or $c -eq '|') -and ($i + 1) -lt $n -and $Command[$i + 1] -eq $c) { $i++ }
            $i++
            continue
        }
        [void]$sb.Append($c)
        $i++
    }
    $segments.Add($sb.ToString())
    return $segments
}

function Split-Argument {
    # Whitespace split with single and double quote grouping. Quotes are
    # removed, backslashes are kept as-is so Windows paths survive.
    param([string]$Segment)
    $tokens = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $quote = [char]0
    $inToken = $false
    foreach ($c in $Segment.ToCharArray()) {
        if ($quote -ne [char]0) {
            if ($c -eq $quote) { $quote = [char]0 } else { [void]$sb.Append($c) }
            continue
        }
        if ($c -eq '"' -or $c -eq "'") {
            $quote = $c
            $inToken = $true
            continue
        }
        if ([char]::IsWhiteSpace($c)) {
            if ($inToken) {
                $tokens.Add($sb.ToString())
                [void]$sb.Clear()
                $inToken = $false
            }
            continue
        }
        [void]$sb.Append($c)
        $inToken = $true
    }
    if ($inToken) { $tokens.Add($sb.ToString()) }
    return $tokens
}

function Get-Tail {
    param([string[]]$Items, [int]$From)
    if ($From -ge $Items.Count) { return @() }
    return @($Items[$From..($Items.Count - 1)])
}

function Test-ShortFlag {
    # True when $Arg is a short flag cluster (-fd, -rf) containing $Letter.
    # Case-sensitive: -d and -D mean different things to git.
    param([string]$Arg, [string]$Letter)
    if ($Arg -notmatch '^-[A-Za-z]+$') { return $false }
    return $Arg.Substring(1).Contains($Letter)
}

function Test-DangerousPath {
    param([string]$Target)
    $t = $Target.Trim()
    if (-not $t) { return $false }
    $homeExpr = '(~|\$HOME|\$\{HOME\}|\$env:USERPROFILE|\$env:HOME|\$\{env:USERPROFILE\}|%USERPROFILE%|%HOME%)'
    $patterns = @(
        '^[\\/]\*?$'                                 # / or /* or \ or \*
        '^\.[\\/]?\*?$'                              # . or ./ or ./* or .\
        '^\.\.[\\/]?\*?$'                            # .. or ../
        '^\*$'                                       # *
        '^:/$'                                       # git pathspec for the whole tree
        "^$homeExpr([\\/]\*?)?`$"                    # ~ or ~/ or ~/* or $HOME etc
        '^[A-Za-z]:([\\/]\*?)?$'                     # C: or C:\ or C:\* or C:/
        '^/(mnt|cygdrive)?/?[A-Za-z]/?\*?$'          # /c, /c/, /c/*, /mnt/c, /cygdrive/c
    )
    foreach ($p in $patterns) {
        if ($t -match $p) { return $true }
    }
    return $false
}

function Resolve-ShellPath {
    # Best-effort conversion of a cd or git -C argument into a Windows path
    # so that git symbolic-ref runs in the right place. Unknown shapes are
    # returned unchanged.
    param([string]$Path, [string]$Cwd)
    $p = $Path.Trim()
    if (-not $p) { return $Cwd }
    if ($p -eq '~' -or $p -like '~/*' -or $p -like '~\*') { return (Join-Path $HOME $p.Substring(1).TrimStart('/', '\')) }
    if ($p -match '^/(mnt/|cygdrive/)?([A-Za-z])(/.*)?$') {
        $drive = $Matches[2].ToUpperInvariant()
        $rest = if ($Matches[3]) { $Matches[3] } else { '/' }
        return ($drive + ':' + $rest)
    }
    if ($p -match '^[A-Za-z]:' -or $p.StartsWith('\\')) { return $p }
    if ($Cwd) { return (Join-Path $Cwd $p) }
    return $p
}

function Get-CurrentBranch {
    param([string]$Cwd)
    try {
        # Local copy of the preference: stderr from git must not throw here.
        $ErrorActionPreference = 'Continue'
        $gitArgs = @()
        if ($Cwd) { $gitArgs += @('-C', $Cwd) }
        $out = & git @gitArgs symbolic-ref --short -q HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return ([string]$out).Trim() }
    } catch {
        # git missing or not a repository. Caller treats null as unknown.
    }
    return $null
}

function Get-RemoteName {
    param([string]$Cwd)
    $fallback = @('origin', 'upstream')
    try {
        $ErrorActionPreference = 'Continue'
        $gitArgs = @()
        if ($Cwd) { $gitArgs += @('-C', $Cwd) }
        $out = @(& git @gitArgs remote 2>$null)
        if ($LASTEXITCODE -eq 0 -and $out.Count -gt 0) {
            return @($out | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) + $fallback
        }
    } catch {
        # Fall through to the defaults.
    }
    return $fallback
}

function Test-GitPush {
    param([string[]]$PushArgs, [string]$Cwd)
    $force = $false
    $delete = $false
    $all = $false
    $positional = @()
    $skipNext = $false
    $afterDashDash = $false
    foreach ($a in $PushArgs) {
        if ($skipNext) { $skipNext = $false; continue }
        if ($afterDashDash) { $positional += $a; continue }
        if ($a -eq '--') { $afterDashDash = $true; continue }
        if ($a.StartsWith('-')) {
            if ($a -eq '--force' -or $a -like '--force-with-lease*' -or $a -eq '--force-if-includes') { $force = $true }
            elseif ($a -eq '--delete') { $delete = $true }
            elseif ($a -in @('--all', '--mirror', '--branches')) { $all = $true }
            elseif ($a -in @('-o', '--push-option', '--receive-pack', '--exec', '--repo')) { $skipNext = $true }
            elseif ($a -match '^-[A-Za-z]+$') {
                if (Test-ShortFlag $a 'f') { $force = $true }
                if (Test-ShortFlag $a 'd') { $delete = $true }
                if (Test-ShortFlag $a 'o') { $skipNext = $true }
            }
            continue
        }
        if ($a.StartsWith('+')) { $force = $true }
        if ($a -match '^\+?:.') { $delete = $true }
        $positional += $a
    }
    if (-not $force -and -not $delete) { return $null }
    if ($force -and $all) {
        return "git push --all or --mirror with a force flag rewrites every branch on the remote, main and master included. Push one feature branch at a time."
    }

    $refspecs = @(Get-Tail $positional 1)
    $targets = @()
    $needCurrent = ($refspecs.Count -eq 0)
    foreach ($spec in $refspecs) {
        $s = $spec.TrimStart('+')
        if ($s -match '[$`]') {
            # Shell expansion in the refspec. The branch is unknown, so
            # fall back to the current branch.
            $needCurrent = $true
            continue
        }
        $src = $s
        $dst = ''
        $colon = $s.IndexOf(':')
        if ($colon -ge 0) {
            $src = $s.Substring(0, $colon)
            $dst = $s.Substring($colon + 1)
        }
        $branch = if ($dst) { $dst } else { $src }
        if (-not $branch -or $branch -eq 'HEAD') { $needCurrent = $true } else { $targets += $branch }
    }
    if ($needCurrent) {
        $current = Get-CurrentBranch -Cwd $Cwd
        if (-not $current) {
            return "git push with a force or delete flag and no explicit branch, and the current branch could not be read from '$Cwd'. Name the branch: git push --force-with-lease origin <feature-branch>."
        }
        $targets += $current
    }
    foreach ($t in $targets) {
        $name = ($t -replace '^refs/heads/', '').ToLowerInvariant()
        if ($name -in $DefaultBranches) {
            if ($delete -and -not $force) {
                return "git push would delete the remote branch '$name'. Deleting main or master is blocked."
            }
            return "git push with a force flag to '$name'. Force pushing main or master rewrites shared history and is blocked. Push to a feature branch and open a pull request instead."
        }
    }
    return $null
}

function Test-GitReset {
    param([string[]]$ResetArgs, [string]$Cwd)
    if ($ResetArgs -notcontains '--hard') { return $null }
    $refs = @($ResetArgs | Where-Object { $_ -and -not $_.StartsWith('-') })
    if ($refs.Count -eq 0) { return $null }
    $remotes = Get-RemoteName -Cwd $Cwd
    foreach ($r in $refs) {
        $isRemote = $false
        if ($r -match '^refs/remotes/' -or $r -match '^@\{u(pstream)?\}$' -or $r -eq 'FETCH_HEAD') { $isRemote = $true }
        foreach ($remote in $remotes) {
            if ($r.StartsWith("$remote/", [StringComparison]::OrdinalIgnoreCase)) { $isRemote = $true }
        }
        if ($isRemote) {
            return "git reset --hard $r discards every local commit and uncommitted change in favour of the remote. Use git stash or a new branch first, or ask the user."
        }
    }
    return $null
}

function Test-GitCheckout {
    param([string[]]$CheckoutArgs)
    $paths = @()
    $dd = [array]::IndexOf($CheckoutArgs, '--')
    if ($dd -ge 0) {
        $paths = @(Get-Tail $CheckoutArgs ($dd + 1))
    } else {
        $paths = @($CheckoutArgs | Where-Object { $_ -and -not $_.StartsWith('-') })
    }
    foreach ($p in $paths) {
        if ($p -in @('.', './', '.\', ':/', '*')) {
            return "git checkout on the whole tree ('$p') throws away every uncommitted change. Name the files, or run git stash first."
        }
    }
    return $null
}

function Test-GitRestore {
    param([string[]]$RestoreArgs)
    $staged = $false
    $worktree = $false
    $skipNext = $false
    $paths = @()
    foreach ($a in $RestoreArgs) {
        if ($skipNext) { $skipNext = $false; continue }
        if ($a -eq '--') { continue }
        if ($a.StartsWith('-')) {
            if ($a -eq '--staged' -or (Test-ShortFlag $a 'S')) { $staged = $true }
            if ($a -eq '--worktree' -or (Test-ShortFlag $a 'W')) { $worktree = $true }
            if ($a -eq '--source' -or $a -ceq '-s') { $skipNext = $true }
            continue
        }
        $paths += $a
    }
    if ($staged -and -not $worktree) { return $null }
    foreach ($p in $paths) {
        if ($p -in @('.', './', '.\', ':/', '*')) {
            return "git restore on the whole tree ('$p') throws away every uncommitted change. Name the files, or run git stash first."
        }
    }
    return $null
}

function Test-GitClean {
    param([string[]]$CleanArgs)
    $force = $false
    $dry = $false
    foreach ($a in $CleanArgs) {
        if ($a -eq '--force' -or (Test-ShortFlag $a 'f')) { $force = $true }
        if ($a -eq '--dry-run' -or (Test-ShortFlag $a 'n')) { $dry = $true }
    }
    if ($force -and -not $dry) {
        return "git clean -f deletes untracked files with no way back. Run git clean -n first and show the user the list."
    }
    return $null
}

function Test-GitBranch {
    param([string[]]$BranchArgs)
    $hardDelete = $false
    $softDelete = $false
    $force = $false
    $names = @()
    foreach ($a in $BranchArgs) {
        if ($a.StartsWith('-')) {
            if (Test-ShortFlag $a 'D') { $hardDelete = $true }
            if ($a -eq '--delete' -or (Test-ShortFlag $a 'd')) { $softDelete = $true }
            if ($a -eq '--force' -or (Test-ShortFlag $a 'f')) { $force = $true }
            continue
        }
        $names += $a
    }
    if (-not ($hardDelete -or ($softDelete -and $force))) { return $null }
    foreach ($n in $names) {
        if ($n.ToLowerInvariant() -in $DefaultBranches) {
            return "git branch -D $n force-deletes the local default branch. Blocked."
        }
    }
    return $null
}

function Test-Git {
    param([string[]]$GitArgs, [string]$Cwd)
    $j = 0
    while ($j -lt $GitArgs.Count -and $GitArgs[$j].StartsWith('-')) {
        if ($GitArgs[$j] -ceq '-C' -and ($j + 1) -lt $GitArgs.Count) {
            $Cwd = Resolve-ShellPath -Path $GitArgs[$j + 1] -Cwd $Cwd
            $j += 2
        } elseif ($GitArgs[$j] -cin @('-c', '--git-dir', '--work-tree', '--namespace', '--exec-path')) {
            $j += 2
        } else {
            $j++
        }
    }
    if ($j -ge $GitArgs.Count) { return $null }
    $sub = $GitArgs[$j].ToLowerInvariant()
    $rest = @(Get-Tail $GitArgs ($j + 1))
    switch ($sub) {
        'push' { return Test-GitPush -PushArgs $rest -Cwd $Cwd }
        'reset' { return Test-GitReset -ResetArgs $rest -Cwd $Cwd }
        'checkout' { return Test-GitCheckout -CheckoutArgs $rest }
        'restore' { return Test-GitRestore -RestoreArgs $rest }
        'clean' { return Test-GitClean -CleanArgs $rest }
        'branch' { return Test-GitBranch -BranchArgs $rest }
    }
    return $null
}

function Test-Rm {
    param([string[]]$RmArgs)
    $recursive = $false
    $noPreserve = $false
    $targets = @()
    $afterDashDash = $false
    foreach ($a in $RmArgs) {
        if ($afterDashDash) { $targets += $a; continue }
        if ($a -eq '--') { $afterDashDash = $true; continue }
        if ($a.StartsWith('-') -and $a.Length -gt 1) {
            if ($a -eq '--recursive' -or (Test-ShortFlag $a 'r') -or (Test-ShortFlag $a 'R')) { $recursive = $true }
            if ($a -eq '--no-preserve-root') { $noPreserve = $true }
            continue
        }
        $targets += $a
    }
    if (-not $recursive) { return $null }
    if ($noPreserve) { return "rm --no-preserve-root is blocked." }
    foreach ($t in $targets) {
        if (Test-DangerousPath $t) {
            return "rm -r on '$t' would delete the whole tree, home directory or drive. Name the directory you mean, for example rm -rf ./build."
        }
    }
    return $null
}

function Test-RemoveItem {
    param([string[]]$RiArgs)
    $recurse = $false
    $targets = @()
    $takeValue = $false
    foreach ($a in $RiArgs) {
        if ($takeValue) {
            $targets += ($a -split ',')
            $takeValue = $false
            continue
        }
        if ($a -match '^/[A-Za-z]$') {
            # cmd.exe style: rmdir /s /q
            if ($a -match '^/[sS]$') { $recurse = $true }
            continue
        }
        if ($a.StartsWith('-')) {
            if ($a -match '^-r(e(c(u(r(s(e)?)?)?)?)?)?(:\$?true)?$') { $recurse = $true }
            if ($a -match '^-(p(a(t(h)?)?)?|l(i(t(e(r(a(l(p(a(t(h)?)?)?)?)?)?)?)?)?)?)$') { $takeValue = $true }
            if ($a -match '^-(f(i(l(t(e(r)?)?)?)?)?|in(c(l(u(d(e)?)?)?)?)?|ex(c(l(u(d(e)?)?)?)?)?)$') { $takeValue = $true }
            continue
        }
        $targets += ($a -split ',')
    }
    if (-not $recurse) { return $null }
    foreach ($t in $targets) {
        if (Test-DangerousPath $t) {
            return "Remove-Item -Recurse on '$t' would delete the whole tree, home directory or drive. Name the directory you mean."
        }
    }
    return $null
}

function Test-TokenSequence {
    param([string[]]$Tokens, [string]$Cwd, [int]$Depth)
    if ($Depth -gt $MaxDepth) { return $null }
    $i = 0
    while ($i -lt $Tokens.Count -and (
            $Tokens[$i] -match '^[A-Za-z_][A-Za-z0-9_]*=' -or
            $Tokens[$i] -match '^\d*[<>]' -or
            $Tokens[$i] -in @('sudo', 'command', 'exec', 'env', 'nohup', 'time', 'builtin'))) { $i++ }
    if ($i -ge $Tokens.Count) { return $null }
    $cmd = (($Tokens[$i] -replace '^.*[\\/]', '') -replace '\.(exe|cmd|bat)$', '').ToLowerInvariant()
    $rest = @(Get-Tail $Tokens ($i + 1))

    switch ($cmd) {
        'git' { return Test-Git -GitArgs $rest -Cwd $Cwd }
        'rm' { return Test-Rm -RmArgs $rest }
        { $_ -in @('remove-item', 'ri', 'del', 'erase', 'rd', 'rmdir') } { return Test-RemoveItem -RiArgs $rest }
        { $_ -in $ShellWrappers } {
            for ($k = 0; $k -lt $rest.Count - 1; $k++) {
                $flag = $rest[$k]
                $inner = $null
                if ($cmd -in @('powershell', 'pwsh')) {
                    if ($flag -match '^-c(o(m(m(a(n(d)?)?)?)?)?)?$') {
                        $inner = (@(Get-Tail $rest ($k + 1)) -join ' ')
                    } elseif ($flag -match '^-e(c|n(c(o(d(e(d(c(o(m(m(a(n(d)?)?)?)?)?)?)?)?)?)?)?)?)?$') {
                        try {
                            $inner = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($rest[$k + 1]))
                        } catch {
                            $inner = $null
                        }
                    }
                } elseif ($cmd -eq 'cmd') {
                    if ($flag -match '^/[ck]$') { $inner = (@(Get-Tail $rest ($k + 1)) -join ' ') }
                } else {
                    if ($flag -ceq '-c') { $inner = $rest[$k + 1] }
                }
                if ($inner) {
                    $verdict = Test-CommandLine -Command $inner -Cwd $Cwd -Depth ($Depth + 1)
                    if ($verdict) { return $verdict }
                }
            }
        }
    }
    return $null
}

function Test-CommandLine {
    param([string]$Command, [string]$Cwd, [int]$Depth)
    # Join line continuations first so a flag on its own line is still seen.
    $text = ($Command -replace '\\\r?\n', ' ') -replace '`\r?\n', ' '
    $effectiveCwd = $Cwd
    foreach ($segment in @(Split-CommandSegment $text)) {
        $tokens = @(Split-Argument $segment)
        if ($tokens.Count -eq 0) { continue }
        if ($tokens[0] -in @('cd', 'pushd', 'set-location', 'sl', 'chdir')) {
            $dirArg = @($tokens | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^[-/]' } | Select-Object -First 1)
            if ($dirArg.Count -eq 1) { $effectiveCwd = Resolve-ShellPath -Path $dirArg[0] -Cwd $effectiveCwd }
            continue
        }
        $verdict = Test-TokenSequence -Tokens $tokens -Cwd $effectiveCwd -Depth $Depth
        if ($verdict) { return $verdict }
    }
    return $null
}

# ---- main ----

$raw = ''
try {
    $stdin = [Console]::OpenStandardInput()
    $buffer = New-Object System.IO.MemoryStream
    $stdin.CopyTo($buffer)
    $raw = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray()).TrimStart([char]0xFEFF)
} catch {
    exit 0
}
if (-not $raw.Trim()) { exit 0 }

try {
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$command = [string]$data.tool_input.command
if (-not $command) { exit 0 }
$cwd = [string]$data.cwd
$toolName = [string]$data.tool_name

$reason = $null
try {
    $reason = Test-CommandLine -Command $command -Cwd $cwd -Depth 0
} catch {
    # A parser bug must not brick the session. Let the call through.
    exit 0
}

if (-not $reason) { exit 0 }

try {
    $logDir = Join-Path $HOME ".claude"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory $logDir | Out-Null }
    $ts = Get-Date -Format "o"
    $oneLine = ($command -replace '\s+', ' ')
    Add-Content -Path (Join-Path $logDir "guard-git.log") -Value "$ts $toolName blocked: $reason | $oneLine"
} catch {
    # Logging is best effort. Never let a log failure turn into an allow.
}

$message = "guard-git: $reason"
try {
    $decision = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = $message
        }
    }
    [Console]::Out.WriteLine(($decision | ConvertTo-Json -Compress))
} catch {
    # Exit 2 blocks on its own; the JSON is the preferred form, not the only one.
}
[Console]::Error.WriteLine($message)
exit 2
