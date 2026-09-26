# D365FO MCP server - team bootstrap (Windows PowerShell 5.1+ / PowerShell 7+)
#
#   irm https://raw.githubusercontent.com/simoafdel-ctrl/Dynamics-365-Finance-Operations/main/team/bootstrap.ps1 | iex
#
# One command on a fresh dev VM: clone (or update) the patched server, build it, then
# hand over to team\Install-TeamMcp.ps1, which detects the environment, asks at most
# three questions, writes every configuration file and verifies the result.
#
# This script is piped through Invoke-Expression, so it cannot take parameters.
# Configuration comes from environment variables, all optional:
#
#   $env:D365FO_MCP_DIR     = 'C:\d365fo-mcp-patched'   # where to clone the server
#   $env:D365FO_MCP_PREFIX  = 'ABC_'                    # object prefix, else asked
#   $env:D365FO_MCP_MODEL   = 'ABC'                     # model, else detected/asked
#   $env:D365FO_MCP_WORKSPACE = 'K:\Projects'           # projects folder, else asked
#   $env:D365FO_MCP_LANGS   = 'en-US,fr-CA'             # label languages, else asked
#   $env:D365FO_MCP_YES     = '1'                       # unattended, take all defaults
#   $env:D365FO_MCP_DRYRUN  = '1'                       # audit only, write nothing
#
# Do NOT use the install.ps1 at the root of this repository: that one belongs to
# upstream and installs the package from npm, which does NOT carry the prefix-first
# patch. Naming would silently fall back to the default style.
#
# NO BARE `exit` IN THIS FILE (the one at the very bottom is guarded, and never runs under
# iex). `irm | iex` runs this text inside the developer's own
# PowerShell session, not as a script, so an `exit` here closes the console window itself.
# That is exactly how the installer's final report used to vanish the instant it was
# printed - and how every BOOTSTRAP STOPPED message vanished with it. Stops are thrown and
# caught at the bottom instead, and the result travels in $LASTEXITCODE.
#
# The whole body runs in a child scope (& { }) for the same reason: without it, the
# 'Stop' error preference and every helper function below would stay behind in the
# developer's session after the install.

& {
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$RepoUrl = 'https://github.com/simoafdel-ctrl/Dynamics-365-Finance-Operations.git'
$TargetDir = $env:D365FO_MCP_DIR
if (-not $TargetDir) { $TargetDir = 'C:\d365fo-mcp-patched' }

# Thrown by Fail and recognised by the catch at the bottom, so a stop that has already
# printed its message is not reported a second time as an unexpected error.
$StopMarker = 'D365FO-BOOTSTRAP-STOPPED'

function Write-Head([string]$m) { Write-Host ''; Write-Host "=== $m" -ForegroundColor Cyan }
function Write-Step([string]$m) { Write-Host "  -> $m" }
function Write-Ok  ([string]$m) { Write-Host "  +  $m" -ForegroundColor Green }
function Fail([string]$m, [string[]]$Hints) {
    Write-Host ''; Write-Host 'BOOTSTRAP STOPPED' -ForegroundColor Red; Write-Host "  $m" -ForegroundColor Red
    if ($Hints) { Write-Host ''; foreach ($h in $Hints) { Write-Host "  - $h" -ForegroundColor Yellow } }
    Write-Host ''
    throw $StopMarker
}

# The repository carries deep paths (eval/goldens/... with long file names). Windows caps
# a path at 260 characters, and git then fails the checkout with "Filename too long",
# leaving a clone that looks successful but has no working tree. -c core.longpaths=true
# makes git use the long-path API and clone correctly whatever the target folder depth.
$GitLongPaths = @('-c', 'core.longpaths=true')

function Invoke-Tool([string]$Exe, [string[]]$Arguments) {
    # git and npm write progress to stderr. Under $ErrorActionPreference='Stop',
    # PowerShell 5.1 turns any native stderr line into a terminating NativeCommandError
    # even when the command succeeds, so the preference is relaxed for the call and the
    # exit code is what decides.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # .ToString() on purpose: 2>&1 wraps stderr lines in ErrorRecord objects, which
        # would otherwise print as "System.Management.Automation.RemoteException".
        & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host ('     ' + $_.ToString()) -ForegroundColor DarkGray }
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
}

function Remove-TreeSafely([string]$Dir) {
    # Remove-Item hits the same 260-character wall as git: on a partial clone it deletes
    # everything except the deep files, leaving a folder that blocks the next attempt.
    # Mirroring an empty folder over it with robocopy clears it whatever the depth -
    # robocopy speaks long paths natively.
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    $empty = Join-Path $env:TEMP ('d365fo-mcp-empty-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $empty -Force
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # robocopy returns 0-7 for success; anything reported here is swallowed on purpose,
        # the Test-Path below is what decides.
        & robocopy $empty $Dir /MIR /NFL /NDL /NJH /NJS /NC /NS /NP 2>&1 | Out-Null
        Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        # robocopy signals success with codes 1-7, which would otherwise travel all the way
        # to this script's own exit code and report a failed bootstrap.
        $global:LASTEXITCODE = 0
    } finally { $ErrorActionPreference = $prev }
}

function Invoke-Clone([string]$Dir) {
    # --quiet: without it, every checkout progress tick arrives as its own line through
    # the pipeline and buries the real messages under a hundred lines of percentages.
    $rc = Invoke-Tool 'git' ($GitLongPaths + @('clone', '--quiet', $RepoUrl, $Dir))
    if ($rc -ne 0) {
        # A failed clone leaves a partial folder WITH a .git in it. Left in place, the next
        # run would take the "update the existing clone" path on a broken working tree and
        # fail in a far more confusing way. Remove it so a retry starts clean.
        if (Test-Path -LiteralPath $Dir) {
            Write-Step 'removing the incomplete clone so a retry starts clean'
            Remove-TreeSafely $Dir
        }
        Fail 'git clone failed - see the output above.' @(
            'If the error mentions "Filename too long", choose a shorter target folder:',
            "  `$env:D365FO_MCP_DIR = 'C:\d365fo-mcp-patched'   then run the command again."
        )
    }
}

try {

Write-Host ''
Write-Host 'D365FO MCP server - team bootstrap' -ForegroundColor White
Write-Host '---------------------------------' -ForegroundColor DarkGray

Write-Head '1. Prerequisites'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail 'Git is not on PATH.' @(
        'Install Git (winget install Git.Git, or https://git-scm.com/download/win),',
        'then CLOSE and REOPEN PowerShell and run this command again.'
    )
}
Write-Ok "Git $((& git --version) -replace 'git version ','')"
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Fail 'Node.js is not on PATH.' @(
        'Install Node.js 24 or later (winget install OpenJS.NodeJS.LTS, or https://nodejs.org),',
        'then CLOSE and REOPEN PowerShell and run this command again.'
    )
}
Write-Ok "Node.js $((& node --version).Trim())"

Write-Head '2. Patched MCP server'
if (Test-Path -LiteralPath (Join-Path $TargetDir '.git')) {
    Push-Location $TargetDir
    try {
        $origin = $null
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $origin = (& git remote get-url origin 2>&1 | Select-Object -First 1) } catch { }
        $ErrorActionPreference = $prevEap
        if ($origin -and ($origin -notlike '*Dynamics-365-Finance-Operations*')) {
            Fail "$TargetDir is a clone of another repository ($origin)." @(
                "Choose a different folder: `$env:D365FO_MCP_DIR = 'C:\d365fo-mcp-team'  then run the command again."
            )
        }
        # Remote and branch are named explicitly: a clone that was not created by `git
        # clone` can have no tracking information, and a bare `git pull` then fails with
        # "There is no tracking information for the current branch".
        $branch = 'main'
        $ErrorActionPreference = 'Continue'
        try {
            $b = (& git rev-parse --abbrev-ref HEAD 2>&1 | Select-Object -First 1)
            if ($b) { $b = $b.ToString().Trim() }
            if ($b -and $b -ne 'HEAD' -and $b -notmatch '\s') { $branch = $b }
        } catch { }
        $ErrorActionPreference = $prevEap
        Write-Step "updating the existing clone (origin/$branch)"
        $rc = Invoke-Tool 'git' ($GitLongPaths + @('pull', '--ff-only', '--quiet', 'origin', $branch))
        if ($rc -ne 0) {
            Fail "git pull could not fast-forward $branch from origin." @(
                'The clone has local commits, uncommitted changes, or has diverged from origin.',
                "Sort it out by hand in $TargetDir (git status), or point `$env:D365FO_MCP_DIR at a fresh folder."
            )
        }
    } finally { Pop-Location }
} elseif (Test-Path -LiteralPath $TargetDir) {
    $hasContent = @(Get-ChildItem -LiteralPath $TargetDir -Force -ErrorAction SilentlyContinue).Count -gt 0
    if ($hasContent) {
        Fail "$TargetDir already exists and is not a git clone." @(
            'Remove it, or set $env:D365FO_MCP_DIR to another folder, then run the command again.'
        )
    }
    Write-Step "cloning into the existing empty folder $TargetDir"
    Invoke-Clone $TargetDir
} else {
    Write-Step "cloning $RepoUrl (takes under a minute)"
    Invoke-Clone $TargetDir
}
Write-Ok "server sources in $TargetDir"

$installer = Join-Path $TargetDir 'team\Install-TeamMcp.ps1'
if (-not (Test-Path -LiteralPath $installer)) {
    Fail "The clone does not contain team\Install-TeamMcp.ps1." @(
        'The clone is probably on an older commit. Run: git -C ' + $TargetDir + ' pull'
    )
}

Write-Head '3. Handing over to the installer'
# The installer builds the server itself when dist is missing or stale, so there is
# nothing to run between the clone and this call.
$argsMap = @{}
if ($env:D365FO_MCP_PREFIX)    { $argsMap['Prefix']         = $env:D365FO_MCP_PREFIX }
if ($env:D365FO_MCP_MODEL)     { $argsMap['Model']          = $env:D365FO_MCP_MODEL }
if ($env:D365FO_MCP_WORKSPACE) { $argsMap['WorkspacePath']  = $env:D365FO_MCP_WORKSPACE }
if ($env:D365FO_MCP_LANGS)     { $argsMap['LabelLanguages'] = @($env:D365FO_MCP_LANGS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
if ($env:D365FO_MCP_YES    -and $env:D365FO_MCP_YES    -ne '0') { $argsMap['Yes']    = $true }
if ($env:D365FO_MCP_DRYRUN -and $env:D365FO_MCP_DRYRUN -ne '0') { $argsMap['DryRun'] = $true }

# The installer is a script file, so its own `exit` ends the installer only and lands
# back here with $LASTEXITCODE set - its report stays on screen.
& $installer @argsMap

} catch {
    # A Fail has already printed its message. Anything else is an unexpected terminating
    # error, from here or from the installer: show it rather than lose it.
    if ([string]$_.Exception.Message -ne $StopMarker) {
        Write-Host ''
        Write-Host 'BOOTSTRAP STOPPED - unexpected error' -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    $global:LASTEXITCODE = 1
}
}

# Only a real script file may pass its exit code on (powershell -File bootstrap.ps1, for
# CI). Under `irm | iex` this is not an ExternalScript, and exiting would close the window.
if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') { exit $LASTEXITCODE }
