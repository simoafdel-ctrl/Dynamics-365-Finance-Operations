<#
.SYNOPSIS
    Removes the team D365FO MCP installation from this machine.

.DESCRIPTION
    Undoes what team\Install-TeamMcp.ps1 wrote: the client registration in both .mcp.json
    files, the generated assistant instruction files, the server configuration, the C#
    metadata bridge, the symbol index and the extraction folder. Optionally the clone too.

    What it reads before deleting anything: the existing d365fo-mcp.json, because that is
    where the index and extraction folders are recorded. An install that parked its 2-3 GB
    index on another drive is removed from there, not from a guessed default.

    Nothing here touches your D365FO metadata. The AOT, your models and your projects are
    not read, moved or deleted - only the MCP server's own files are.

.PARAMETER KeepIndex
    Leave the symbol index and the extraction folder in place. Use it when you intend to
    reinstall: rebuilding them is the 15-45 minute part of an install.

.PARAMETER RemoveServer
    Also delete the server clone (C:\d365fo-mcp-patched by default). Left in place
    otherwise, because a clone costs nothing to keep and a reinstall reuses it.

.PARAMETER DryRun
    Print what would be removed and write nothing.

.EXAMPLE
    C:\d365fo-mcp-patched\team\Uninstall-TeamMcp.ps1 -DryRun
    Show exactly what a removal would touch.

.EXAMPLE
    C:\d365fo-mcp-patched\team\Uninstall-TeamMcp.ps1 -KeepIndex
    Unregister the server and drop its configuration, but keep the index for a reinstall.

.EXAMPLE
    C:\d365fo-mcp-patched\team\Uninstall-TeamMcp.ps1 -RemoveServer -Yes
    Remove everything, including the clone, without asking.
#>
[CmdletBinding()]
param(
    [string] $ServerRoot,
    [string] $ConfigRoot,
    [string] $WorkspacePath,
    [switch] $KeepIndex,
    [switch] $RemoveServer,
    [switch] $Yes,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$script:Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:Removed = New-Object System.Collections.ArrayList
$script:Kept    = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------- output helpers
# ASCII only, for the same reason as the installer: PowerShell 5.1 on a Windows Server
# console turns non-ASCII glyphs into mojibake.
function Write-Head([string]$m) { Write-Host ''; Write-Host "=== $m" -ForegroundColor Cyan }
function Write-Step([string]$m) { Write-Host "  -> $m" }
function Write-Ok  ([string]$m) { Write-Host "  +  $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "  !  $m" -ForegroundColor Yellow }

function Stop-Uninstall([string]$m, [string[]]$Hints) {
    Write-Host ''
    Write-Host 'UNINSTALL STOPPED' -ForegroundColor Red
    Write-Host "  $m" -ForegroundColor Red
    if ($Hints) { Write-Host ''; foreach ($h in $Hints) { Write-Host "  - $h" -ForegroundColor Yellow } }
    Write-Host ''
    exit 1
}

function Remove-DeepFolder([string]$Path, [string]$Label) {
    # Remove-Item -Recurse trips over the >260 character paths inside node_modules. Mirroring
    # an empty folder over the target first empties it with the short relative paths robocopy
    # uses internally, which is the same trick TROUBLESHOOTING.md documents for a broken clone.
    if (-not (Test-Path -LiteralPath $Path)) { Write-Step "already gone: $Label"; return }
    if ($DryRun) { Write-Step "would remove $Label  ($Path)"; $null = $script:Removed.Add($Path); return }
    $empty = Join-Path $env:TEMP "d365fo-mcp-empty-$($script:Stamp)"
    $null = New-Item -ItemType Directory -Path $empty -Force
    try {
        $null = robocopy $empty $Path /MIR /NFL /NDL /NJH /NJS /NP
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Ok "removed $Label"
        $null = $script:Removed.Add($Path)
    } catch {
        Write-Warn "could not remove $Label - $($_.Exception.Message)"
        Write-Warn "remove it by hand: $Path"
    } finally {
        Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-Simple([string]$Path, [string]$Label, [switch]$Backup) {
    if (-not (Test-Path -LiteralPath $Path)) { Write-Step "already gone: $Label"; return }
    if ($DryRun) { Write-Step "would remove $Label  ($Path)"; $null = $script:Removed.Add($Path); return }
    if ($Backup -and -not (Test-Path -LiteralPath $Path -PathType Container)) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak-$($script:Stamp)" -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
    Write-Ok "removed $Label"
    $null = $script:Removed.Add($Path)
}

# ================================================================ 0. what is installed
Write-Host ''
Write-Host 'D365FO MCP server - team uninstall' -ForegroundColor White
Write-Host '----------------------------------'
if ($DryRun) { Write-Warn 'DRY RUN - nothing will be removed.' }

Write-Head '0. Locating the installation'

if (-not $ConfigRoot) { $ConfigRoot = Join-Path $env:LOCALAPPDATA 'd365fo-mcp\installation\config' }
$installRoot = Split-Path -Parent $ConfigRoot
$stateRoot   = Split-Path -Parent $installRoot          # %LOCALAPPDATA%\d365fo-mcp
$configFile  = Join-Path $ConfigRoot 'd365fo-mcp.json'

# The config is the only record of where a non-default index or extraction folder lives, so
# it is read before anything is deleted. Guessing the defaults would leave several GB behind.
$indexDir = $null
$extractDir = $null
if (Test-Path -LiteralPath $configFile) {
    Write-Ok "configuration   $configFile"
    try {
        $cfg = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
        if ($cfg.index) {
            if ($cfg.index.dbPath)       { $indexDir   = Split-Path -Parent ([string]$cfg.index.dbPath) }
            if ($cfg.index.metadataPath) { $extractDir = [string]$cfg.index.metadataPath }
        }
    } catch {
        Write-Warn 'the configuration is not valid JSON - falling back to the default folders'
    }
} else {
    Write-Warn "no configuration at $configFile"
}
if (-not $indexDir)   { $indexDir   = Join-Path $installRoot 'data' }
if (-not $extractDir) { $extractDir = Join-Path $installRoot 'extracted-metadata' }
Write-Ok "index           $indexDir"
Write-Ok "extraction      $extractDir"

# The clone: taken from what the clients were told to execute, so a non-default location is
# found rather than assumed.
$mcpFiles = @(
    (Join-Path $env:USERPROFILE '.mcp.json'),
    $(if ($WorkspacePath) { Join-Path $WorkspacePath '.mcp.json' } else { $null }),
    (Join-Path $installRoot '.mcp.json')
) | Where-Object { $_ }

if (-not $ServerRoot) {
    foreach ($f in $mcpFiles) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            $entry = $j.mcpServers.'d365fo-mcp-tools'
            if (-not $entry) { $entry = $j.servers.'d365fo-mcp-tools' }
            if ($entry -and $entry.args -and $entry.args[0]) {
                # <root>\dist\index.js -> <root>
                $ServerRoot = Split-Path -Parent (Split-Path -Parent ([string]$entry.args[0]))
                break
            }
        } catch { }
    }
}
if (-not $ServerRoot) { $ServerRoot = 'C:\d365fo-mcp-patched' }
Write-Ok "server clone    $ServerRoot"

# The workspace holds the two generated instruction files. solutionsPath in the config is the
# authoritative value; the parameter overrides it.
if (-not $WorkspacePath -and (Test-Path -LiteralPath $configFile)) {
    try {
        $cfg2 = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
        if ($cfg2.workspace -and $cfg2.workspace.solutionsPath) { $WorkspacePath = [string]$cfg2.workspace.solutionsPath }
    } catch { }
}
if ($WorkspacePath) {
    Write-Ok "workspace       $WorkspacePath"
    $mcpFiles += (Join-Path $WorkspacePath '.mcp.json')
} else {
    Write-Warn 'no workspace folder known - pass -WorkspacePath to clean up CLAUDE.md there'
}
$mcpFiles = @($mcpFiles | Select-Object -Unique)

# ================================================================ 1. nothing may be running
Write-Head '1. Running servers'

# Files held open cannot be deleted, and a server that survives the uninstall keeps answering
# from an index this script is about to remove.
$running = @()
try {
    $running = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop |
                 Where-Object { $_.CommandLine -and $_.CommandLine -match 'd365fo-mcp' })
} catch { Write-Warn 'could not enumerate processes - close your editors before continuing' }

if ($running.Count -gt 0) {
    foreach ($p in $running) { Write-Warn "PID $($p.ProcessId): $($p.CommandLine)" }
    if (-not $DryRun) {
        Stop-Uninstall "$($running.Count) MCP server process(es) are still running." @(
            'Close VS Code and Visual Studio - Claude Code and Copilot each start their own server.',
            'They hold the bridge and the index open, so removing them would fail halfway.',
            'Then run this script again.'
        )
    }
} else {
    Write-Ok 'no MCP server is running'
}

# ================================================================ 2. confirm
Write-Head '2. What will be removed'

Write-Host '     client registration in:'
foreach ($f in $mcpFiles) { if (Test-Path -LiteralPath $f) { Write-Host "       $f" } }
Write-Host "     configuration and bridge : $installRoot"
if ($KeepIndex) {
    Write-Host "     index                    : KEPT ($indexDir)" -ForegroundColor Yellow
    Write-Host "     extraction               : KEPT ($extractDir)" -ForegroundColor Yellow
} else {
    Write-Host "     index                    : $indexDir"
    Write-Host "     extraction               : $extractDir"
}
if ($WorkspacePath) { Write-Host "     generated instructions   : CLAUDE.md, .github\copilot-instructions.md in $WorkspacePath" }
if ($RemoveServer) { Write-Host "     server clone             : $ServerRoot" }
else { Write-Host "     server clone             : KEPT ($ServerRoot) - pass -RemoveServer to delete it" -ForegroundColor Yellow }

if (-not $DryRun -and -not $Yes) {
    Write-Host ''
    $answer = Read-Host '  Type REMOVE to continue'
    if ($answer -ne 'REMOVE') { Write-Host ''; Write-Host '  Cancelled - nothing was removed.' -ForegroundColor Yellow; Write-Host ''; exit 0 }
}

# ================================================================ 3. unregister the clients
Write-Head '3. Client registration'

# The entry is removed key by key rather than deleting the file: a developer may well have
# other MCP servers in the same .mcp.json, and those are not ours to throw away.
foreach ($f in $mcpFiles) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Step "not present: $f"; continue }
    try {
        $json = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    } catch {
        Write-Warn "$f is not valid JSON - left untouched"
        continue
    }
    $touched = $false
    foreach ($key in @('servers', 'mcpServers')) {
        $section = $json.$key
        if ($section -and ($section.PSObject.Properties.Name -contains 'd365fo-mcp-tools')) {
            $section.PSObject.Properties.Remove('d365fo-mcp-tools')
            $touched = $true
        }
    }
    if (-not $touched) { Write-Step "no d365fo-mcp-tools entry in $f"; continue }

    $remaining = 0
    foreach ($key in @('servers', 'mcpServers')) {
        if ($json.$key) { $remaining += @($json.$key.PSObject.Properties).Count }
    }

    if ($DryRun) {
        if ($remaining -eq 0) { Write-Step "would delete $f (no other MCP server in it)" }
        else { Write-Step "would remove the d365fo-mcp-tools entry from $f, keeping $remaining other server(s)" }
        $null = $script:Removed.Add($f)
        continue
    }

    Copy-Item -LiteralPath $f -Destination "$f.bak-$($script:Stamp)" -Force
    if ($remaining -eq 0) {
        Remove-Item -LiteralPath $f -Force
        Write-Ok "deleted $f (it held no other MCP server)"
    } else {
        $out = $json | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($f, $out, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "unregistered from $f, kept $remaining other server(s)"
    }
    $null = $script:Removed.Add($f)
}

# ================================================================ 4. generated files
Write-Head '4. Generated instruction files'

if ($WorkspacePath) {
    # Backed up rather than simply deleted: these are generated from the templates, but a
    # developer may have added notes to their local copy despite being told not to.
    Remove-Simple (Join-Path $WorkspacePath 'CLAUDE.md') 'CLAUDE.md' -Backup
    Remove-Simple (Join-Path $WorkspacePath '.github\copilot-instructions.md') 'copilot-instructions.md' -Backup
} else {
    Write-Step 'skipped - no workspace folder known'
}

# ================================================================ 5. server files
Write-Head '5. Configuration, bridge and index'

if ($KeepIndex) {
    # Remove the installation folder without taking the index with it, in case it sits inside.
    Remove-Simple $ConfigRoot 'configuration folder'
    Remove-Simple (Join-Path $installRoot 'bridge') 'metadata bridge'
    $null = $script:Kept.Add($indexDir)
    $null = $script:Kept.Add($extractDir)
    Write-Warn "kept the index     $indexDir"
    Write-Warn "kept the extraction $extractDir"
} else {
    Remove-DeepFolder $extractDir 'extraction folder'
    Remove-Simple $indexDir 'symbol index'
    Remove-Simple $installRoot 'installation folder'
    # Only if nothing else of ours lives beside it.
    if ((Test-Path -LiteralPath $stateRoot) -and -not $DryRun) {
        $left = @(Get-ChildItem -LiteralPath $stateRoot -Force -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) { Remove-Simple $stateRoot 'state folder' }
    }
}

# ================================================================ 6. the clone
Write-Head '6. Server clone'

if (-not $RemoveServer) {
    Write-Warn "kept $ServerRoot  (pass -RemoveServer to delete it)"
    $null = $script:Kept.Add($ServerRoot)
} else {
    $here = $PSScriptRoot
    $insideClone = $here -and $here.ToLowerInvariant().StartsWith($ServerRoot.ToLowerInvariant())
    if ($insideClone) {
        # Stepping out matters: a process whose working directory is inside the folder keeps a
        # handle on it, and the delete fails on the last few entries.
        Set-Location $env:TEMP
        Write-Step 'this script lives inside the clone - deleting it from outside'
    }
    Remove-DeepFolder $ServerRoot 'server clone'
    if ($insideClone -and (Test-Path -LiteralPath $ServerRoot)) {
        Write-Warn 'the clone could not delete itself while running from inside it. Finish with:'
        Write-Host "    Remove-Item '$ServerRoot' -Recurse -Force" -ForegroundColor Yellow
    }
}

# ================================================================ report
Write-Host ''
Write-Host '=== Report' -ForegroundColor Cyan
if ($script:Removed.Count -eq 0) { Write-Host '  Nothing was found to remove.' -ForegroundColor Yellow }
else {
    # A dry run must not claim things are gone while they are all still there.
    $tag = if ($DryRun) { '[WOULD GO]' } else { '[GONE]   ' }
    foreach ($r in $script:Removed) { Write-Host "  $tag $r" -ForegroundColor Green }
}
foreach ($k in $script:Kept) { Write-Host "  [KEPT] $k" -ForegroundColor Yellow }

Write-Host ''
if ($DryRun) {
    Write-Host '  Dry run complete - nothing was removed.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

Write-Host '  Uninstall complete.' -ForegroundColor Green
Write-Host ''
Write-Host '  Worth knowing:' -ForegroundColor White
Write-Host '    - Your D365FO metadata was not touched. Models, projects and the AOT are as they were.'
Write-Host "    - Backups were left as <name>.bak-$($script:Stamp) next to each file that had one."
Write-Host '    - Restart VS Code and Visual Studio so they stop trying to start the server.'
if ($KeepIndex) { Write-Host '    - The index was kept, so a reinstall skips the long step.' }
Write-Host ''
