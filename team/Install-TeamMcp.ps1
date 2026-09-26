#Requires -Version 5.1
<#
.SYNOPSIS
    Installs and configures the patched D365FO MCP server (prefix-first naming) on a
    D365FO development VM, for both Claude Code and GitHub Copilot in Visual Studio.

.DESCRIPTION
    One command, nothing to finish by hand. The script follows four principles:

      1. DETECT  what can be detected  (packages path, model, bridge, workspace)
      2. ASK     only what cannot be deduced (prefix, label languages, workspace)
      3. VALIDATE every value before it is used
      4. VERIFY  every file that was written, and report file by file

    Values are never hard-coded for a client: everything comes from detection on the
    machine or from a validated answer. The instruction files handed to Claude Code and
    Copilot are rendered from the generic templates in team/templates.

    Scope: TRADITIONAL environments only (a local PackagesLocalDirectory). A Unified
    Developer Environment (UDE) is detected and refused with a clear message rather
    than configured from a guess.

.PARAMETER Prefix
    Object prefix for new objects and CoC classes, e.g. ABC_ (a trailing underscore is
    optional - it is normalised). Default: the model name plus an underscore.

.PARAMETER Model
    Custom model to target. Default: detected. Only asked when several custom models
    exist and none was passed.

.PARAMETER PackagePath
    PackagesLocalDirectory. Default: detected on the fixed drives.

.PARAMETER WorkspacePath
    Folder where the developer keeps solutions/projects. Receives CLAUDE.md,
    .github\copilot-instructions.md and a .mcp.json.

.PARAMETER LabelLanguages
    Label languages, first one is the primary, e.g. en-US,fr-CA. Validated against the
    languages actually present in the metadata.

.PARAMETER ServerRoot
    Clone of the patched MCP server. Default: the parent folder of this script.

.PARAMETER ConfigRoot
    Folder for d365fo-mcp.json. Default: %LOCALAPPDATA%\d365fo-mcp\installation\config

.PARAMETER Yes
    Non-interactive: take every default, ask nothing. Fails instead of guessing when a
    value is genuinely ambiguous (for example several custom models and no -Model).

.PARAMETER DryRun
    Detect, validate and run the read-only tests, write nothing. Use it to check an
    already-installed machine without touching its configuration.

.PARAMETER SkipBuild
    Do not run npm install / npm run build. Only when dist/ is known to be current.

.EXAMPLE
    .\Install-TeamMcp.ps1
    Interactive install: detects everything, asks at most three questions.

.EXAMPLE
    .\Install-TeamMcp.ps1 -DryRun
    Non-destructive audit of a machine that is already installed.

.EXAMPLE
    .\Install-TeamMcp.ps1 -Prefix ABC_ -LabelLanguages en-US,fr-CA -Yes
    Unattended install for onboarding several machines.
#>
[CmdletBinding()]
param(
    [string]   $Prefix,
    [string]   $Model,
    [string]   $PackagePath,
    [string]   $WorkspacePath,
    [string[]] $LabelLanguages,
    [string]   $ServerRoot,
    [string]   $ConfigRoot,
    [string]   $MetadataWorkPath,
    [string]   $IndexPath,
    [switch]   $Yes,
    [switch]   $DryRun,
    [switch]   $SkipBuild,
    [switch]   $SkipIndex,
    [switch]   $ForceIndex
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$script:MinNodeMajor = 24   # package.json engines: node >= 24.0.0
$script:Checks       = New-Object System.Collections.ArrayList
$script:Written      = New-Object System.Collections.ArrayList
$script:Stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'

# ---------------------------------------------------------------- output helpers
# ASCII only on purpose: a UTF-8 script without BOM read by PowerShell 5.1 on a
# Windows Server console turns non-ASCII glyphs into mojibake. Colour carries the
# meaning instead.
function Write-Head([string]$m) { Write-Host ''; Write-Host "=== $m" -ForegroundColor Cyan }
function Write-Step([string]$m) { Write-Host "  -> $m" }
function Write-Ok  ([string]$m) { Write-Host "  +  $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "  !  $m" -ForegroundColor Yellow }
function Write-Bad ([string]$m) { Write-Host "  x  $m" -ForegroundColor Red }

function Stop-Install([string]$m, [string[]]$Hints) {
    Write-Host ''
    Write-Host "INSTALL STOPPED" -ForegroundColor Red
    Write-Host "  $m" -ForegroundColor Red
    if ($Hints) { Write-Host ''; foreach ($h in $Hints) { Write-Host "  - $h" -ForegroundColor Yellow } }
    Write-Host ''
    exit 1
}

function Add-Check([string]$Name, [bool]$Pass, [string]$Detail) {
    $null = $script:Checks.Add([pscustomobject]@{ Name = $Name; Pass = $Pass; Detail = $Detail })
}

# ---------------------------------------------------------------- input helpers
function Read-Answer([string]$Question, [string]$Default) {
    if ($Yes) { return $Default }
    if ($Default) { $prompt = "$Question [$Default]" } else { $prompt = $Question }
    $answer = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Select-FromList([string]$Question, [string[]]$Items) {
    if ($Items.Count -eq 1) { return $Items[0] }
    if ($Yes) { return $null }   # caller decides how to fail: never guess
    Write-Host ''
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ("    [{0}] {1}" -f ($i + 1), $Items[$i]) }
    while ($true) {
        $raw = Read-Host "  $Question (1-$($Items.Count))"
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return $Items[$n - 1] }
        Write-Warn "Enter a number between 1 and $($Items.Count)."
    }
}

# ---------------------------------------------------------------- file helpers
function Write-TextFile([string]$Path, [string]$Content) {
    # UTF-8 WITHOUT BOM: a BOM in front of a JSON document breaks strict parsers, and
    # some MCP clients are strict. Existing installs written by the wizard carry one.
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        if ($DryRun) { Write-Step "would create folder $dir" }
        else { $null = New-Item -ItemType Directory -Path $dir -Force }
    }
    $same = $false
    if (Test-Path -LiteralPath $Path) {
        $current = [System.IO.File]::ReadAllText($Path)
        if ($current -eq $Content) { $same = $true }
        elseif ($DryRun) { Write-Step "would back up $Path -> $(Split-Path -Leaf $Path).bak-$($script:Stamp)" }
        else {
            $backup = "$Path.bak-$($script:Stamp)"
            Copy-Item -LiteralPath $Path -Destination $backup -Force
            Write-Step "backed up -> $(Split-Path -Leaf $backup)"
        }
    }
    if ($same) { Write-Ok "unchanged  $Path"; $null = $script:Written.Add($Path); return }
    if ($DryRun) { Write-Step "would write $Path"; $null = $script:Written.Add($Path); return }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "wrote      $Path"
    $null = $script:Written.Add($Path)
}

function ConvertTo-PrettyJson($Object) {
    # PowerShell 5.1 has no JsonSerializerOptions; ConvertTo-Json is enough here and
    # escapes backslashes in Windows paths correctly.
    return ($Object | ConvertTo-Json -Depth 12)
}

function Test-IndexDatabase([string]$DbPath) {
    # Symbols = rows in the symbol table, Locked = a live server holds the file.
    # Both answers come from one node launch; node:sqlite ships with Node 24.
    $probeFile = Join-Path $env:TEMP "d365fo-mcp-dbprobe-$($script:Stamp)-$([guid]::NewGuid().ToString('N').Substring(0,6)).mjs"
    $literal = $DbPath.Replace('\', '\\')
    $code = @"
import { DatabaseSync } from 'node:sqlite';
import { existsSync } from 'node:fs';
const p = '$literal';
if (!existsSync(p)) { console.log('SYMBOLS=0'); console.log('LOCK=free'); process.exit(0); }
let n = 0;
let reader;
try {
  // MAX(rowid) is O(1); COUNT(*) on a multi-GB index blocks for a minute.
  reader = new DatabaseSync(p, { readOnly: true });
  const row = reader.prepare('SELECT MAX(rowid) AS c FROM symbols').get();
  n = (row && row.c) ? row.c : 0;
} catch { n = 0; } finally {
  // Closing matters: an open read handle - even this one, even read-only, even in this
  // process - is exactly what the journal switch below refuses to share. Leaving it open
  // reports every existing database as locked.
  try { if (reader) reader.close(); } catch { }
}
console.log('SYMBOLS=' + n);
// Reproduce the exact condition the build needs, which is stricter than BEGIN EXCLUSIVE:
// build-database switches the journal to MEMORY (scripts/build-database.ts), and SQLite
// refuses that while any other connection holds the WAL - even an idle reader. Testing it
// with BEGIN EXCLUSIVE instead reports "free" and the build then dies on its first pragma.
let writer;
try {
  writer = new DatabaseSync(p);
  writer.exec('PRAGMA journal_mode = MEMORY');
  writer.exec('PRAGMA journal_mode = WAL');   // put it back: the probe must not change the file
  console.log('LOCK=free');
} catch { console.log('LOCK=busy'); } finally {
  try { if (writer) writer.close(); } catch { }
}
"@
    [System.IO.File]::WriteAllText($probeFile, $code, (New-Object System.Text.UTF8Encoding($false)))
    $out = Invoke-Native 'node' @($probeFile)
    Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
    $symbols = 0
    if ($out -match 'SYMBOLS=(\d+)') { $symbols = [int]$Matches[1] }
    return [pscustomobject]@{ Symbols = $symbols; Locked = ($out -match 'LOCK=busy') }
}

function Get-FreeGb([string]$Path) {
    # -1 when the drive cannot be read, so callers can tell "no room" from "unknown".
    try {
        $qualifier = Split-Path -Qualifier $Path
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$qualifier'" -ErrorAction Stop
        if ($disk) { return [math]::Round($disk.FreeSpace / 1GB, 1) }
    } catch { }
    return -1
}

function Invoke-Tool([string]$Exe, [string[]]$Arguments) {
    # npm and git write progress and warnings to stderr. Under
    # $ErrorActionPreference='Stop', PowerShell 5.1 turns any native stderr line into a
    # terminating NativeCommandError even when the command succeeded, so the preference is
    # relaxed for the call and the exit code is what decides. Output is echoed indented so
    # a long npm install still shows progress.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # .ToString() on purpose: 2>&1 wraps stderr lines in ErrorRecord objects, which
        # would otherwise print as "System.Management.Automation.RemoteException".
        & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host ('     ' + $_.ToString()) -ForegroundColor DarkGray }
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
}

function Invoke-Native([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec = 120) {
    # Runs a native exe with stdin already closed and returns its combined output.
    # stdin matters: the metadata bridge enters a stdin loop and would hang on a
    # console that stays open.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = ($null | & $Exe @Arguments 2>&1 | Out-String)
        return $out
    } catch {
        return "EXCEPTION: $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $prev
    }
}

# ================================================================ 0. preflight
Write-Host ''
Write-Host 'D365FO MCP server - team install (prefix-first naming)' -ForegroundColor White
Write-Host '------------------------------------------------------' -ForegroundColor DarkGray
if ($DryRun) { Write-Warn 'DRY RUN - detection and read-only tests only, nothing will be written.' }

Write-Head '0. Prerequisites'

$nodeExe = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeExe) {
    Stop-Install 'Node.js is not on PATH.' @(
        'Install Node.js 24 or later from https://nodejs.org (or: winget install OpenJS.NodeJS.LTS)',
        'Then CLOSE and REOPEN PowerShell so PATH is refreshed, and run this script again.'
    )
}
$nodeVersion = (& node --version).Trim()
$nodeMajor = 0
if ($nodeVersion -match '^v(\d+)') { $nodeMajor = [int]$Matches[1] }
if ($nodeMajor -lt $script:MinNodeMajor) {
    Stop-Install "Node.js $nodeVersion is too old - the server requires >= $($script:MinNodeMajor).0.0." @(
        'Install a current Node.js LTS, reopen PowerShell, and run this script again.'
    )
}
Write-Ok "Node.js $nodeVersion"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warn 'Git is not on PATH - fine if the server is already cloned, required to update it.'
} else {
    Write-Ok "Git $((& git --version) -replace 'git version ','')"
}

# ================================================================ 1. server root
Write-Head '1. Patched MCP server'

if (-not $ServerRoot) { $ServerRoot = Split-Path -Parent $PSScriptRoot }
$ServerRoot = [System.IO.Path]::GetFullPath($ServerRoot)

if (-not (Test-Path -LiteralPath (Join-Path $ServerRoot 'package.json'))) {
    Stop-Install "No package.json under $ServerRoot - this is not the MCP server clone." @(
        'Run the script from inside the clone (team\Install-TeamMcp.ps1), or pass -ServerRoot <path>.'
    )
}
$pkg = Get-Content -LiteralPath (Join-Path $ServerRoot 'package.json') -Raw | ConvertFrom-Json
Write-Ok "server $($pkg.name) $($pkg.version)  ($ServerRoot)"

# The patch marker. This is the check that catches the most expensive mistake of all:
# pointing the clients at the UNPATCHED package from npm, where naming silently falls
# back to the default style and nobody notices until objects are already created.
$patchMarkerFiles = @(
    (Join-Path $ServerRoot 'src\utils\modelClassifier.ts'),
    (Join-Path $ServerRoot 'dist\utils\modelClassifier.js')
)
$patched = $false
foreach ($f in $patchMarkerFiles) {
    if ((Test-Path -LiteralPath $f) -and (Select-String -LiteralPath $f -Pattern 'prefix-first' -SimpleMatch -Quiet)) {
        $patched = $true; break
    }
}
if (-not $patched) {
    Stop-Install "The server at $ServerRoot does not carry the prefix-first patch." @(
        'This is probably the vanilla package from npm instead of the internal fork.',
        'Clone the fork and run the script from there:',
        '  git clone <fork-url> C:\d365fo-mcp-patched',
        '  C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1'
    )
}
Write-Ok 'prefix-first patch present'

$distEntry = Join-Path $ServerRoot 'dist\index.js'
if ($SkipBuild) {
    Write-Step 'skipping build (-SkipBuild)'
} elseif ($DryRun) {
    Write-Step 'would run npm install + npm run build if dist is missing or stale'
} else {
    $needBuild = -not (Test-Path -LiteralPath $distEntry)
    if (-not $needBuild) {
        $newestSrc = Get-ChildItem -LiteralPath (Join-Path $ServerRoot 'src') -Recurse -File -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($newestSrc -and $newestSrc.LastWriteTimeUtc -gt (Get-Item -LiteralPath $distEntry).LastWriteTimeUtc) {
            $needBuild = $true
            Write-Step 'dist is older than src - rebuilding'
        }
    }
    if ($needBuild) {
        Push-Location $ServerRoot
        try {
            Write-Step 'npm install (a few minutes on a first run)'
            $rc = Invoke-Tool 'npm' @('install', '--no-fund', '--no-audit')
            if ($rc -ne 0) { Stop-Install 'npm install failed - see the output above.' }
            Write-Step 'npm run build'
            $rc = Invoke-Tool 'npm' @('run', 'build')
            if ($rc -ne 0) { Stop-Install 'npm run build failed - see the output above.' }
        } finally { Pop-Location }
    } else {
        Write-Ok 'dist is current'
    }
}
if (-not (Test-Path -LiteralPath $distEntry) -and -not $DryRun) {
    Stop-Install "Build produced no $distEntry."
}

# ================================================================ 2. environment
Write-Head '2. D365FO environment'

# --- UDE first, so an unsupported box gets a clear answer instead of a guessed config.
$udeHits = @()
$udeRoots = @("$env:LOCALAPPDATA\Microsoft\Dynamics365", "$env:LOCALAPPDATA\Microsoft\Dynamics 365")
foreach ($r in $udeRoots) {
    if (Test-Path -LiteralPath $r) {
        $udeHits += Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { Join-Path $_.FullName 'PackagesLocalDirectory' } |
                    Where-Object { Test-Path -LiteralPath $_ }
    }
}

function Test-PackagePath([string]$Path) {
    if (-not $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    # The bridge does Path.Combine(packagesPath, "bin") and loads the metadata assembly
    # from there. A path without that DLL is the exact cause of
    #   [FATAL] D365FO bin path not found: <path>\bin
    return (Test-Path -LiteralPath (Join-Path $Path 'bin\Microsoft.Dynamics.AX.Metadata.dll'))
}

$existingConfigPath = $null
if (-not $ConfigRoot) { $ConfigRoot = Join-Path $env:LOCALAPPDATA 'd365fo-mcp\installation\config' }
$candidateConfig = Join-Path $ConfigRoot 'd365fo-mcp.json'
$existingConfig = $null
if (Test-Path -LiteralPath $candidateConfig) {
    try {
        $existingConfig = Get-Content -LiteralPath $candidateConfig -Raw | ConvertFrom-Json
        $existingConfigPath = $candidateConfig
        Write-Step "found an existing configuration: $candidateConfig"
    } catch { Write-Warn "existing $candidateConfig is not valid JSON - it will be backed up and replaced" }
}

$pkgCandidates = New-Object System.Collections.ArrayList
foreach ($c in @(
    $PackagePath,
    $(if ($existingConfig) { $existingConfig.environment.packagePath } else { $null }),
    $env:D365FO_PACKAGE_PATH
)) { if ($c -and (Test-PackagePath $c)) { $null = $pkgCandidates.Add([System.IO.Path]::GetFullPath($c)) } }

if ($pkgCandidates.Count -eq 0) {
    Write-Step 'scanning fixed drives for AosService\PackagesLocalDirectory'
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
        $guess = Join-Path $d.RootDirectory.FullName 'AosService\PackagesLocalDirectory'
        if (Test-PackagePath $guess) { $null = $pkgCandidates.Add([System.IO.Path]::GetFullPath($guess)) }
    }
}

$pkgCandidates = @($pkgCandidates | Select-Object -Unique)

if ($pkgCandidates.Count -eq 0) {
    if ($udeHits.Count -gt 0) {
        Stop-Install 'UDE detected - not covered by this version of the installer.' @(
            "Unified Developer Environment metadata found at: $($udeHits[0])",
            'This installer supports TRADITIONAL environments (a local AosService\PackagesLocalDirectory) only.',
            'A UDE variant will be added once a real UDE box is available to test it against.',
            'Refusing to write a guessed configuration.'
        )
    }
    Stop-Install 'No PackagesLocalDirectory found with bin\Microsoft.Dynamics.AX.Metadata.dll in it.' @(
        'Pass it explicitly: -PackagePath K:\AosService\PackagesLocalDirectory (use the drive of this VM).',
        'If this machine is a UDE, this installer does not support it yet.'
    )
}

if ($pkgCandidates.Count -gt 1) {
    Write-Warn "several PackagesLocalDirectory candidates found"
    $picked = Select-FromList 'Which one is this environment?' $pkgCandidates
    if (-not $picked) { Stop-Install 'Several candidates and -Yes was passed.' @('Pass -PackagePath <path> explicitly.') }
    $PackagePath = $picked
} else {
    $PackagePath = $pkgCandidates[0]
}
Write-Ok "packages path  $PackagePath"
if ($udeHits.Count -gt 0) { Write-Warn 'UDE artefacts also present on this machine - the traditional path above is being used.' }

# --- custom model: detected from the descriptors, never typed.
Write-Step 'reading model descriptors (custom models are the ones not published by Microsoft)'
$customModels = New-Object System.Collections.ArrayList
foreach ($moduleDir in Get-ChildItem -LiteralPath $PackagePath -Directory -ErrorAction SilentlyContinue) {
    $descDir = Join-Path $moduleDir.FullName 'Descriptor'
    if (-not (Test-Path -LiteralPath $descDir)) { continue }
    foreach ($desc in Get-ChildItem -LiteralPath $descDir -Filter '*.xml' -File -ErrorAction SilentlyContinue) {
        try {
            $xml = [xml](Get-Content -LiteralPath $desc.FullName -Raw)
            $name      = [string]$xml.AxModelInfo.Name
            $publisher = [string]$xml.AxModelInfo.Publisher
        } catch { continue }
        if (-not $name) { continue }
        if ($publisher -match 'Microsoft') { continue }
        # The server writes into <packagePath>\<model>\<model>, so that folder must exist.
        if (-not (Test-Path -LiteralPath (Join-Path $PackagePath (Join-Path $name $name)))) { continue }
        if ($customModels -notcontains $name) { $null = $customModels.Add($name) }
    }
}
$customModels = @($customModels | Sort-Object)

if (-not $Model -and $existingConfig -and $existingConfig.workspace) {
    # Idempotence: a machine already configured keeps its model on a re-run, so nobody
    # has to remember -Model. Switching model stays an explicit, deliberate -Model.
    $previous = [string]$existingConfig.workspace.modelName
    if ($previous -and (Test-Path -LiteralPath (Join-Path $PackagePath (Join-Path $previous $previous)))) {
        $Model = $previous
        Write-Step "keeping the model already configured on this machine ($Model) - pass -Model to change it"
    }
}

if ($Model) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackagePath (Join-Path $Model $Model)))) {
        Stop-Install "Model '$Model' has no folder $PackagePath\$Model\$Model." @('Drop -Model to let the script detect it.')
    }
    Write-Ok "model          $Model"
} elseif ($customModels.Count -eq 0) {
    Stop-Install "No custom model found under $PackagePath." @(
        'Create the model in Visual Studio first (Dynamics 365 > Model management > Create model),',
        'then run this script again. Or pass -Model <name> if it exists under another publisher.'
    )
} elseif ($customModels.Count -eq 1) {
    $Model = $customModels[0]
    Write-Ok "model          $Model  (detected - the only custom model)"
} else {
    Write-Warn "$($customModels.Count) custom models on this environment"
    $picked = Select-FromList 'Which model should the MCP server write into?' $customModels
    if (-not $picked) {
        Stop-Install 'Several custom models and -Yes was passed.' @("Pass -Model with one of: $($customModels -join ', ')")
    }
    $Model = $picked
    Write-Ok "model          $Model"
}
$modelWritePath = Join-Path $PackagePath (Join-Path $Model $Model)

# --- bridge: deploy it next to its dependencies, and never reuse an intermediate build.
#
# Two traps this block exists to avoid, both of which shipped a bridge that started and
# then died on its first request:
#
#  * `npm run bridge:build` is a COMPILE GATE, not a deployment. It builds into a scratch
#    temp folder on purpose (see scripts/bridgeBuild.mjs) and leaves the deployed binary
#    untouched, so it never produces anything runnable here.
#  * the leftover obj\Release output is not runnable either. It holds the assembly alone,
#    without the NuGet dependencies, so the bridge initialises its MetadataProvider, logs
#    "initialized successfully", and then throws FileNotFoundException on
#    System.Threading.Tasks.Extensions the moment System.Text.Json serialises its ready
#    handshake. Picking it up with a recursive Get-ChildItem is what used to happen.
#
# `dotnet build -o <dir>` copies the dependencies next to the exe, which is what makes the
# difference between "an exe exists" and "the bridge can answer".
$bridgeDeployDir = Join-Path (Split-Path -Parent $ConfigRoot) 'bridge'
$bridgeExe       = Join-Path $bridgeDeployDir 'D365MetadataBridge.exe'
$bridgeProject   = Join-Path $ServerRoot 'bridge\D365MetadataBridge'
# Sentinel dependency: present in a real deployment, absent from obj\Release. Testing for
# it is how a half-deployed bridge is told apart from a complete one.
$bridgeDep       = Join-Path $bridgeDeployDir 'System.Threading.Tasks.Extensions.dll'

$bridgeReady = (Test-Path -LiteralPath $bridgeExe) -and (Test-Path -LiteralPath $bridgeDep)
if ($bridgeReady) {
    # Sources newer than the deployed exe mean a pull landed since the last install.
    $exeStamp = (Get-Item -LiteralPath $bridgeExe).LastWriteTimeUtc
    $newestSrc = Get-ChildItem -LiteralPath $bridgeProject -Recurse -Include '*.cs', '*.csproj' -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch '\\obj\\' } |
                 Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($newestSrc -and $newestSrc.LastWriteTimeUtc -gt $exeStamp) {
        Write-Step 'bridge sources are newer than the deployed binary - redeploying'
        $bridgeReady = $false
    }
} elseif (Test-Path -LiteralPath $bridgeExe) {
    Write-Step 'deployed bridge is missing its dependencies - redeploying'
}

if (-not $bridgeReady) {
    if ($DryRun) {
        Write-Step "would deploy the bridge to $bridgeDeployDir (dotnet build -c Release)"
    } else {
        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
            Stop-Install 'The C# metadata bridge must be deployed and the .NET SDK is not on PATH.' @(
                'Install the .NET SDK (https://dotnet.microsoft.com/download), reopen PowerShell, run this script again.'
            )
        }
        Write-Step "deploying the bridge to $bridgeDeployDir"
        $null = New-Item -ItemType Directory -Path $bridgeDeployDir -Force
        $rc = Invoke-Tool 'dotnet' @('build', $bridgeProject, '-c', 'Release', '--no-incremental', '-o', $bridgeDeployDir)
        if ($rc -ne 0) { Stop-Install 'dotnet build of the metadata bridge failed - see the output above.' }
        if (-not (Test-Path -LiteralPath $bridgeExe)) {
            Stop-Install "The bridge build reported success but produced no exe at $bridgeExe"
        }
        if (-not (Test-Path -LiteralPath $bridgeDep)) {
            Stop-Install 'The bridge was built without its NuGet dependencies.' @(
                "Expected $bridgeDep next to the exe.",
                'Without it the bridge dies on its first response with a FileNotFoundException.'
            )
        }
    }
}
Write-Ok "bridge         $bridgeExe"

# --- label languages available on disk, used to validate the answer below.
$availableLanguages = @()
$langProbe = Get-ChildItem -LiteralPath $PackagePath -Directory -ErrorAction SilentlyContinue |
             ForEach-Object { Join-Path $_.FullName '*\AxLabelFile\LabelResources' } |
             ForEach-Object { Get-Item -Path $_ -ErrorAction SilentlyContinue } |
             Select-Object -First 1
if ($langProbe) {
    $availableLanguages = @(Get-ChildItem -LiteralPath $langProbe.FullName -Directory -ErrorAction SilentlyContinue |
                           Select-Object -ExpandProperty Name)
}
if ($availableLanguages.Count -gt 0) { Write-Ok "$($availableLanguages.Count) label languages available in the metadata" }

# ================================================================ 3. questions
Write-Head '3. Values that cannot be detected'

# --- prefix
if (-not $Prefix -and $existingConfig -and $existingConfig.naming) { $Prefix = [string]$existingConfig.naming.prefix }
$prefixDefault = $Prefix
if (-not $prefixDefault) { $prefixDefault = "$Model" + '_' }
while ($true) {
    $answer = Read-Answer '  Object prefix for new objects and CoC classes' $prefixDefault
    if ($answer -match '^[A-Za-z][A-Za-z0-9]{0,19}_?$') { $Prefix = $answer; break }
    Write-Warn 'A prefix starts with a letter, then letters/digits, with an optional trailing underscore (e.g. ABC_).'
    if ($Yes) { Stop-Install "Invalid prefix: '$answer'" }
}
$prefixBare = $Prefix.TrimEnd('_')          # the patch strips a trailing underscore itself
$prefixStored = $prefixBare + '_'           # stored with the underscore, as the server expects
Write-Ok "prefix         $prefixStored"

# --- label languages
if (-not $LabelLanguages -and $existingConfig -and $existingConfig.index -and $existingConfig.index.labelLanguages) {
    $LabelLanguages = @($existingConfig.index.labelLanguages)
}
$langDefault = 'en-US'
if ($LabelLanguages -and $LabelLanguages.Count -gt 0) { $langDefault = ($LabelLanguages -join ',') }
while ($true) {
    $answer = Read-Answer '  Label languages, primary first, comma separated' $langDefault
    $parsed = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $bad = @()
    foreach ($l in $parsed) {
        if ($availableLanguages.Count -gt 0) {
            if ($availableLanguages -notcontains $l) { $bad += $l }
        } elseif ($l -notmatch '^[a-z]{2,3}(-[A-Za-z0-9]{2,4})?$') { $bad += $l }
    }
    if ($parsed.Count -gt 0 -and $bad.Count -eq 0) { $LabelLanguages = $parsed; break }
    if ($bad.Count -gt 0) {
        Write-Warn "not a language present in this metadata: $($bad -join ', ')"
        # This is the fr-CA vs FR mistake, caught before it reaches the config.
        $near = @($availableLanguages | Where-Object { $_ -like "$($bad[0].Substring(0,[Math]::Min(2,$bad[0].Length)))*" } | Select-Object -First 8)
        if ($near.Count -gt 0) { Write-Warn "did you mean: $($near -join ', ')" }
    } else { Write-Warn 'Give at least one language.' }
    if ($Yes) { Stop-Install "Invalid label languages: '$answer'" }
}
Write-Ok "labels         $($LabelLanguages -join ', ')"

# --- workspace
if (-not $WorkspacePath -and $existingConfig -and $existingConfig.workspace) {
    $WorkspacePath = [string]$existingConfig.workspace.solutionsPath
}
$wsDefault = $WorkspacePath
if (-not $wsDefault) { $wsDefault = Join-Path $env:USERPROFILE 'source\repos' }
while ($true) {
    $answer = Read-Answer '  Folder where you keep your D365FO projects' $wsDefault
    try {
        $full = [System.IO.Path]::GetFullPath($answer)
        if (-not [System.IO.Path]::IsPathRooted($full)) { throw 'not absolute' }
        $WorkspacePath = $full.TrimEnd('\')
        break
    } catch {
        Write-Warn 'Give an absolute path, for example C:\Users\you\source\repos or K:\Projects.'
        if ($Yes) { Stop-Install "Invalid workspace path: '$answer'" }
    }
}
if (-not (Test-Path -LiteralPath $WorkspacePath)) {
    if ($DryRun) { Write-Step "would create $WorkspacePath" }
    else { $null = New-Item -ItemType Directory -Path $WorkspacePath -Force; Write-Step "created $WorkspacePath" }
}
Write-Ok "workspace      $WorkspacePath"

# ================================================================ 4. write config
Write-Head '4. Configuration files'

$installRoot = Split-Path -Parent $ConfigRoot

# --- where the extraction dumps its JSON before the database load.
# Only ~1.5 GB of JSON, but spread over ~190,000 tiny files: on a volume with large
# allocation units that occupies closer to 10 GB, and it is read exactly once, by the
# database build. On these VMs the system drive is the small one and the packages drive is
# the large one, so an install that defaults it next to the config is the install that runs
# out of disk.
if (-not $MetadataWorkPath) {
    $MetadataWorkPath = Join-Path $installRoot 'extracted-metadata'
    $freeHere = Get-FreeGb $MetadataWorkPath
    $freeThere = Get-FreeGb $PackagePath
    # 25 GB, not 15: the extraction plus the index need ~13 GB, and filling the system
    # drive to its last couple of GB breaks more than this install.
    if ($freeHere -ge 0 -and $freeHere -lt 25 -and $freeThere -gt $freeHere) {
        $MetadataWorkPath = Join-Path (Split-Path -Qualifier $PackagePath) '\d365fo-mcp-data\extracted-metadata'
        Write-Warn "only $freeHere GB free on the installation drive - extracting to $MetadataWorkPath instead ($freeThere GB free)"
    }
}
Write-Ok "extract folder $MetadataWorkPath"

# --- where the symbol index lives.
# Kept overridable, and an override already recorded in the config is honoured rather than
# reset: a 2-3 GB index is sometimes deliberately parked off the system drive, and silently
# writing the default back would point the server at an empty database next to this file.
if (-not $IndexPath) {
    if ($existingConfig -and $existingConfig.index -and $existingConfig.index.dbPath) {
        $IndexPath = Split-Path -Parent ([string]$existingConfig.index.dbPath)
    } else {
        $IndexPath = Join-Path $installRoot 'data'
    }
}
$dbPath       = Join-Path $IndexPath 'xpp-metadata.db'
$labelsDbPath = Join-Path $IndexPath 'xpp-metadata-labels.db'
Write-Ok "index folder   $IndexPath"

# --- server configuration
$serverConfig = [ordered]@{
    version     = 1
    environment = [ordered]@{
        type         = 'traditional'
        packagePath  = $PackagePath
        customModels = @($Model)
    }
    workspace   = [ordered]@{
        modelName     = $Model          # the MODEL, never the prefix
        path          = $modelWritePath
        solutionsPath = $WorkspacePath
    }
    naming      = [ordered]@{
        prefix        = $prefixStored
        prefixSource  = 'config'        # use the prefix as given, do not infer one
        extensionStyle = 'prefix-first' # the team convention; absent by default
    }
    index       = [ordered]@{
        extractMode    = 'all'
        includeLabels  = $true
        labelLanguages = @($LabelLanguages)
        bpCatalogPath  = './data/bp-moniker-catalog.json'
        # Recorded so the server and the index step below agree on one location. Left to
        # its default the server resolves it relative to this file and would look in a
        # folder the extraction never wrote to.
        metadataPath   = $MetadataWorkPath
        dbPath         = $dbPath
        labelsDbPath   = $labelsDbPath
    }
    server      = [ordered]@{ mode = 'full' }
    bridge      = [ordered]@{ exePath = $bridgeExe }
}
$serverConfigPath = Join-Path $ConfigRoot 'd365fo-mcp.json'
Write-TextFile $serverConfigPath (ConvertTo-PrettyJson $serverConfig)

# --- client configuration
# Every value is passed as an environment variable and not left to the config file:
# launched from an arbitrary working folder, the server does not reliably apply the
# values from d365fo-mcp.json (observed: "Model name: (not configured)", "0 model(s)").
$serverEntry = [ordered]@{
    command = 'node'
    args    = @($distEntry)
    env     = [ordered]@{
        D365FO_CONFIG               = $serverConfigPath
        D365FO_PACKAGE_PATH         = $PackagePath
        # Identical to D365FO_PACKAGE_PATH on purpose. The server reads this variable
        # first and it short-circuits an XPP auto-detection that, after a VM restart,
        # can resolve to the solutions folder - the bridge then looks for
        # <solutions>\bin, fails with [FATAL] D365FO bin path not found, and every
        # write fails with "C# metadata bridge is not available".
        D365FO_CUSTOM_PACKAGES_PATH = $PackagePath
        D365FO_MODEL_NAME           = $Model
        D365FO_BRIDGE_EXE_PATH      = $bridgeExe
        # Same reason as the paths above: passed explicitly rather than left to the config
        # file. A server that falls back to the default resolves ./data next to its config
        # and opens an empty database, which looks like a healthy install that finds nothing.
        DB_PATH                     = $dbPath
        LABELS_DB_PATH              = $labelsDbPath
        METADATA_PATH               = $MetadataWorkPath
        EXTENSION_NAMING_STYLE      = 'prefix-first'
        EXTENSION_PREFIX            = $prefixStored
        EXTENSION_PREFIX_SOURCE     = 'config'
    }
}
# Two keys, same content: Claude Code reads mcpServers, Copilot reads servers. With only
# one of them present the other client fails to parse the file.
$clientConfig = [ordered]@{
    servers    = [ordered]@{ 'd365fo-mcp-tools' = $serverEntry }
    mcpServers = [ordered]@{ 'd365fo-mcp-tools' = $serverEntry }
}
$clientJson = ConvertTo-PrettyJson $clientConfig

# Two locations. Claude Code reads the .mcp.json of the open working folder (walking up
# from it); Copilot reads the one in the user profile. A workspace on another drive never
# walks up to %USERPROFILE%, so both are written.
$mcpTargets = @(
    (Join-Path $env:USERPROFILE '.mcp.json'),
    (Join-Path $WorkspacePath '.mcp.json')
)
# A wizard-generated installation\.mcp.json points at the global npm package, which is
# NOT patched. Anything reading it gets the default naming style. Overwrite it.
$legacyMcp = Join-Path (Split-Path -Parent $ConfigRoot) '.mcp.json'
if (Test-Path -LiteralPath $legacyMcp) {
    Write-Step 'found a stale .mcp.json in the installation folder (points at the unpatched npm package)'
    $mcpTargets += $legacyMcp
}
foreach ($t in ($mcpTargets | Select-Object -Unique)) { Write-TextFile $t $clientJson }

# ================================================================ 5. instructions
Write-Head '5. Assistant instruction files'

$templateDir = Join-Path $PSScriptRoot 'templates'
$langInline = ($LabelLanguages -join ' and ')
$langJson   = (($LabelLanguages | ForEach-Object { '"' + $_ + '"' }) -join ', ')
$tokens = [ordered]@{
    '{{PREFIX}}'                = $prefixStored
    '{{PREFIX_BARE}}'           = $prefixBare
    '{{MODEL}}'                 = $Model
    '{{LABEL_LANGUAGES_INLINE}}'= $langInline
    '{{LABEL_LANGUAGES_JSON}}'  = $langJson
    '{{WORKSPACE}}'             = $WorkspacePath
    '{{SERVER_ROOT}}'           = $ServerRoot
    '{{GENERATED_ON}}'          = (Get-Date -Format 'yyyy-MM-dd')
}
function Render-Template([string]$TemplatePath, [string]$OutPath) {
    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        Stop-Install "Missing template: $TemplatePath" @('The team\templates folder must travel with this script.')
    }
    $text = [System.IO.File]::ReadAllText($TemplatePath)
    foreach ($k in $tokens.Keys) { $text = $text.Replace($k, [string]$tokens[$k]) }
    $left = [regex]::Matches($text, '\{\{[A-Z_]+\}\}')
    if ($left.Count -gt 0) {
        $names = ($left | ForEach-Object { $_.Value } | Select-Object -Unique) -join ', '
        Stop-Install "Template $([System.IO.Path]::GetFileName($TemplatePath)) still contains unresolved tokens: $names"
    }
    Write-TextFile $OutPath $text
}
Render-Template (Join-Path $templateDir 'CLAUDE.md')                 (Join-Path $WorkspacePath 'CLAUDE.md')
Render-Template (Join-Path $templateDir 'copilot-instructions.md')   (Join-Path $WorkspacePath '.github\copilot-instructions.md')

# ================================================================ 6. metadata index
Write-Head '6. Metadata index'

# Without this step the install completes and every symbol tool answers nothing: `search`
# finds no object, `get_object_info` reports even a standard table as "not found via
# bridge, symbol index, or on disk", and scope="extensions" claims no custom model exists.
# The database file alone is not enough - the wizard creates the schema, and a schema with
# zero rows looks exactly like a healthy install until someone searches.
#
# `d365fo-mcp index` is deliberately NOT used here. It resolves its data root to the repo
# root whenever the server is a git checkout (src/cli/context.ts: `if (installMode ===
# 'git') return repoRoot`, which also ignores D365FO_MCP_HOME), and this layout is a git
# checkout whose config and data live under %LOCALAPPDATA% instead. It would build a
# database in the clone that the server never opens. The paths are passed explicitly.
$extractTs = Join-Path $ServerRoot 'scripts\extract-metadata.ts'

if ($DryRun) {
    Write-Step "would extract metadata to $MetadataWorkPath, then build $dbPath"
} elseif ($SkipIndex) {
    Write-Warn '-SkipIndex: the index was left untouched. Symbol tools stay empty until it is built.'
} elseif (-not (Test-Path -LiteralPath $extractTs)) {
    Write-Warn "no scripts\extract-metadata.ts under $ServerRoot - cannot index from this layout."
} else {
    $null = New-Item -ItemType Directory -Path $IndexPath -Force

    # Probe before building: a rebuild is 15-45 minutes, so a populated index is left alone
    # unless -ForceIndex. The same probe reports whether a server still holds the file -
    # build-database takes locking_mode = EXCLUSIVE and cannot share it with a live server.
    $probe      = Test-IndexDatabase $dbPath
    $symbolsNow = $probe.Symbols
    $dbLocked   = $probe.Locked

    if ($symbolsNow -gt 0 -and -not $ForceIndex) {
        Write-Ok "index already populated ($symbolsNow symbols) - pass -ForceIndex to rebuild"
    } elseif ($dbLocked) {
        Stop-Install 'The metadata database is held by a running MCP server, so it cannot be rebuilt.' @(
            'Close VS Code and Visual Studio (Claude Code and Copilot each start their own server), then run this script again.',
            'The database build needs exclusive access: SQLite cannot grant it while a server holds the file.'
        )
    } else {
        Write-Step 'this runs once and takes 15-45 minutes on a full AOT - leave the window open'
        $env:METADATA_PATH       = $MetadataWorkPath
        $env:DB_PATH             = $dbPath
        $env:LABELS_DB_PATH      = $labelsDbPath
        $env:D365FO_PACKAGE_PATH = $PackagePath
        $env:EXTRACT_MODE        = 'all'
        $env:CUSTOM_MODELS       = $Model
        $env:INCLUDE_LABELS      = 'true'

        Push-Location $ServerRoot
        try {
            Write-Step '[1/2] extracting metadata from the packages folder (XML -> JSON)'
            $rc = Invoke-Tool 'npm' @('run', 'extract-metadata')
            if ($rc -ne 0) { Stop-Install 'Metadata extraction failed - see the output above.' }

            Write-Step '[2/2] building the symbol database (JSON -> SQLite)'
            $rc = Invoke-Tool 'npm' @('run', 'build-database')
            if ($rc -ne 0) {
                Stop-Install 'The database build failed - see the output above.' @(
                    'If it failed on a locked database, close every editor that starts an MCP server and re-run.'
                )
            }
        } finally { Pop-Location }
        Write-Ok 'index built'
    }
}

# ================================================================ 7. verification
Write-Head '7. Verification'

# (a) naming, run against the compiled code with this environment values.
# dist can legitimately be absent here: -DryRun and -SkipBuild both skip the build. That
# is not a naming failure, and reporting it as one would send someone hunting the wrong
# problem - so it is called what it is.
$namingModulePath = Join-Path $ServerRoot 'dist\utils\objectNaming.js'
$expectClass = "$prefixBare" + '_CustTable_Extension'
$expectTable = "CustTable.$Model"
if (-not (Test-Path -LiteralPath $namingModulePath)) {
    Write-Warn 'naming test skipped: dist is not built yet (expected with -DryRun or -SkipBuild).'
    Write-Warn 'Run the installer without those switches to build and test for real.'
} else {

$namingScript = Join-Path $env:TEMP "d365fo-mcp-naming-$($script:Stamp).mjs"
$namingModule = ([Uri](Join-Path $ServerRoot 'dist\utils\objectNaming.js')).AbsoluteUri
$namingCode = @"
const m = await import('$namingModule');
const noop = () => {};
console.log(m.normalizeObjectName('CustTable', 'class-extension', '$Model', noop));
console.log(m.normalizeObjectName('CustTable', 'table-extension', '$Model', noop));
"@
[System.IO.File]::WriteAllText($namingScript, $namingCode, (New-Object System.Text.UTF8Encoding($false)))
$env:EXTENSION_NAMING_STYLE  = 'prefix-first'
$env:EXTENSION_PREFIX        = $prefixStored
$env:EXTENSION_PREFIX_SOURCE = 'config'
$namingOut = Invoke-Native 'node' @($namingScript)
Remove-Item -LiteralPath $namingScript -Force -ErrorAction SilentlyContinue
$namingLines = @($namingOut -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$namingPass = ($namingLines -contains $expectClass) -and ($namingLines -contains $expectTable)
Add-Check 'naming: CoC class extension' ($namingLines -contains $expectClass) "expected $expectClass"
Add-Check 'naming: dot-notation extension' ($namingLines -contains $expectTable) "expected $expectTable"
if (-not $namingPass) { Write-Warn "naming test output was: $($namingLines -join ' | ')" }

}   # end of the naming test

# (b) the bridge answers against this packages path.
#
# The assertion is the ready handshake, NOT "MetadataProvider initialized successfully".
# That line is printed BEFORE the first serialisation, so a bridge deployed without its
# NuGet dependencies prints it and then dies - and this check used to pass on a bridge that
# could not answer a single request. Only the handshake proves it got through
# System.Text.Json and reached its stdin loop.
$bridgeOut = Invoke-Native $bridgeExe @('--packages-path', $PackagePath)
$bridgePass = $bridgeOut -match '"status"\s*:\s*"ready"'
Add-Check 'bridge answers its ready handshake' $bridgePass 'expected a {"id":"ready"} line with status ready'
if (-not $bridgePass) {
    Write-Warn 'bridge output:'
    Write-Host $bridgeOut -ForegroundColor DarkGray
    if ($bridgeOut -match 'bin path not found') {
        Write-Warn "the packages path is wrong - the bridge needs the folder that CONTAINS bin\Microsoft.Dynamics.AX.Metadata.dll"
    }
    if ($bridgeOut -match 'Could not load file or assembly') {
        Write-Warn 'the bridge is missing its NuGet dependencies - it was deployed from an intermediate'
        Write-Warn 'obj\ folder instead of a real output folder. Re-run without -DryRun to redeploy it.'
    }
}
Add-Check 'bridge has its dependencies' (Test-Path -LiteralPath $bridgeDep) $bridgeDep

# (c) the symbol index holds symbols.
# This is the one failure that looks like a healthy install: every tool responds, the
# report is green, and every search comes back empty because the schema has no rows.
if ($DryRun -or $SkipIndex) {
    Write-Warn 'index check skipped (-DryRun / -SkipIndex) - symbol tools stay empty until it is built.'
} else {
    $idxState = Test-IndexDatabase $dbPath
    Add-Check 'symbol index is populated' ($idxState.Symbols -gt 0) "$dbPath holds $($idxState.Symbols) symbols"
}

# (d) every file landed, and says what it must say
if ((-not (Test-Path -LiteralPath $distEntry)) -and ($DryRun -or $SkipBuild)) {
    # Same reasoning as the naming test: a missing dist under -DryRun/-SkipBuild is the
    # switch doing its job, not a broken install. Reporting it as a failure would send
    # someone looking for a problem that is not there.
    Write-Warn 'dist\index.js is not built yet - a real install builds it first.'
} else {
    Add-Check 'server entry point  dist\index.js' (Test-Path -LiteralPath $distEntry) $distEntry
}
Add-Check 'metadata bridge     D365MetadataBridge.exe' (Test-Path -LiteralPath $bridgeExe) $bridgeExe
if ($DryRun) {
    Write-Warn 'dry run: the file checks below describe what an install would have written.'
} else {
    Add-Check 'server config       d365fo-mcp.json' (Test-Path -LiteralPath $serverConfigPath) $serverConfigPath
    foreach ($t in ($mcpTargets | Select-Object -Unique)) {
        $okFile = Test-Path -LiteralPath $t
        $detail = $t
        if ($okFile) {
            try {
                $j = Get-Content -LiteralPath $t -Raw | ConvertFrom-Json
                $hasBoth = ($j.PSObject.Properties.Name -contains 'servers') -and ($j.PSObject.Properties.Name -contains 'mcpServers')
                $e = $j.mcpServers.'d365fo-mcp-tools'.env
                $samePath = ($e.D365FO_CUSTOM_PACKAGES_PATH -eq $e.D365FO_PACKAGE_PATH)
                $pointsAtPatched = ($j.mcpServers.'d365fo-mcp-tools'.args[0] -eq $distEntry)
                $okFile = $hasBoth -and $samePath -and $pointsAtPatched
                if (-not $hasBoth)         { $detail = "$t - missing the servers/mcpServers pair" }
                elseif (-not $samePath)    { $detail = "$t - D365FO_CUSTOM_PACKAGES_PATH differs from D365FO_PACKAGE_PATH" }
                elseif (-not $pointsAtPatched) { $detail = "$t - does not point at the patched server" }
            } catch { $okFile = $false; $detail = "$t - invalid JSON" }
        }
        Add-Check "client config       $(Split-Path -Leaf (Split-Path -Parent $t))\.mcp.json" $okFile $detail
    }
    Add-Check 'Claude Code         CLAUDE.md' (Test-Path -LiteralPath (Join-Path $WorkspacePath 'CLAUDE.md')) (Join-Path $WorkspacePath 'CLAUDE.md')
    Add-Check 'Copilot             copilot-instructions.md' (Test-Path -LiteralPath (Join-Path $WorkspacePath '.github\copilot-instructions.md')) (Join-Path $WorkspacePath '.github\copilot-instructions.md')
}

# ================================================================ report
Write-Host ''
Write-Host '=== Report' -ForegroundColor Cyan
$failed = 0
foreach ($c in $script:Checks) {
    if ($c.Pass) { Write-Host ("  [ OK ] " + $c.Name) -ForegroundColor Green }
    else { Write-Host ("  [FAIL] " + $c.Name) -ForegroundColor Red; Write-Host ("         " + $c.Detail) -ForegroundColor DarkGray; $failed++ }
}

Write-Host ''
Write-Host '  Environment' -ForegroundColor White
Write-Host "    model      : $Model"
Write-Host "    prefix     : $prefixStored"
Write-Host "    packages   : $PackagePath"
Write-Host "    workspace  : $WorkspacePath"
Write-Host "    labels     : $($LabelLanguages -join ', ')"
Write-Host "    naming     : $expectClass  |  $expectTable"

if ($failed -gt 0) {
    Write-Host ''
    Write-Host "  $failed check(s) failed - see team/docs/TROUBLESHOOTING.md" -ForegroundColor Red
    Write-Host ''
    exit 1
}

Write-Host ''
if ($DryRun) {
    Write-Host '  Dry run complete - nothing was written.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}
Write-Host '  Install complete.' -ForegroundColor Green
Write-Host ''
Write-Host '  Next, once each:' -ForegroundColor White
Write-Host "    1. VS Code: open the folder  code `"$WorkspacePath`""
Write-Host '       In the Claude Code panel (spark icon), approve the d365fo-mcp-tools server when'
Write-Host '       asked, then ask it to call get_workspace_info. /mcp shows the server status.'
Write-Host '    2. Visual Studio: restart it so Copilot picks up the new .mcp.json.'
Write-Host '    3. Prove the convention on a throwaway object - trust the file name on disk,'
Write-Host '       not what the assistant says it created:'
Write-Host "         Get-ChildItem '$modelWritePath' -Recurse -Filter '*CustTable*Extension*'"
Write-Host ''
exit 0
