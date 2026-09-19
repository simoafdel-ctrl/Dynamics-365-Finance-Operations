# Installing on a new dev VM — step by step

Follow this top to bottom on a fresh D365FO development VM. At the end, Claude Code and GitHub
Copilot both drive the patched MCP server with our team conventions already applied: naming,
mandatory best-practice checks, English XML documentation, the right label languages.

Budget **45–75 minutes**, nearly all of it waiting: a few minutes on `npm install`, then
15–45 minutes while the installer indexes your AOT. Both phases print little or nothing for long
stretches. Start it and go do something else.

Placeholders used throughout: `ABC_` is an object prefix, `ABC` a model name, `K:\` the drive
holding the AOS. Substitute what your own machine reports — the installer detects them and
prints them back to you.

---

## Before you start — 5 minutes

Run these four commands in PowerShell and note what you get:

```powershell
node --version                                      # want v24 or higher
git --version                                       # any recent version
Get-ChildItem C:\,D:\,J:\,K:\ -Filter AosService -ErrorAction SilentlyContinue   # find the AOS drive
$PSVersionTable.PSVersion                           # 5.1 or 7.x, both fine
```

| Requirement | Why it matters |
|---|---|
| **Node.js 24+** | the server declares `node >= 24.0.0`; older versions fail the build, not the install |
| **Git** | used to clone the fork |
| **A traditional environment** — a local `AosService\PackagesLocalDirectory` | UDE is not supported yet, see [ARCHITECTURE.md](ARCHITECTURE.md#scope-traditional-only) |
| **A custom model already created** | the server needs somewhere to write; create it in Visual Studio first if absent |
| **~15 GB free** on some drive | the extraction is ~1.5 GB of JSON but lands in ~190 000 tiny files, so it occupies nearer 10 GB on a volume with large clusters; the index adds 2–3 GB. The installer picks the roomiest drive and tells you which |
| **Admin rights** | only if you still need to install Node or Git |

Nothing else. You do **not** need Visual Studio open, and you do not need the AOS running.

---

## Step 1 — Install Node.js and Git, if missing

Skip if both commands above answered.

```powershell
winget install OpenJS.NodeJS.LTS
winget install Git.Git
```

On a Windows Server VM without winget, take the installers from [nodejs.org](https://nodejs.org)
and [git-scm.com](https://git-scm.com/download/win).

> **Close and reopen PowerShell afterwards.** This is not optional and it is the single most
> common way this install goes wrong: your current session still holds the old `PATH`, so
> `node` or `git` will not be found even though they are installed. Reopen, re-run
> `node --version`, and only continue once it answers.

---

## Step 2 — Confirm the environment is supported

```powershell
# the packages path must contain the platform bin with the metadata assembly
Test-Path 'K:\AosService\PackagesLocalDirectory\bin\Microsoft.Dynamics.AX.Metadata.dll'
```

`True` means you have a traditional environment and the C# bridge will be able to start. If it
is `False` on every drive, stop here: either the path is elsewhere (find it with the
`Get-ChildItem` above) or this is a UDE, which this installer refuses on purpose rather than
configuring from a guess.

Then look at which custom models exist — you will recognise the one you are meant to work in:

```powershell
Get-ChildItem 'K:\AosService\PackagesLocalDirectory' -Directory |
  Where-Object { Test-Path "$($_.FullName)\Descriptor" } |
  ForEach-Object { Get-ChildItem "$($_.FullName)\Descriptor\*.xml" } |
  ForEach-Object { $x=[xml](Get-Content $_.FullName); if ($x.AxModelInfo.Publisher -notmatch 'Microsoft') { "$($x.AxModelInfo.Name)  ($($x.AxModelInfo.Publisher))" } }
```

You do not have to write the model down — the installer detects it. This is just so the value it
proposes does not surprise you. If several appear, it will ask you to pick.

---

## Step 3 — Run the installer

One command:

```powershell
irm https://raw.githubusercontent.com/simoafdel-ctrl/Dynamics-365-Finance-Operations/main/team/bootstrap.ps1 | iex
```

It clones the patched server to `C:\d365fo-mcp-patched`, builds it, then runs the installer.

To clone somewhere else, set the folder first — keep it **short**, Windows caps paths at 260
characters and this repository has deep ones:

```powershell
$env:D365FO_MCP_DIR = 'D:\tools\d365fo-mcp'
irm https://raw.githubusercontent.com/simoafdel-ctrl/Dynamics-365-Finance-Operations/main/team/bootstrap.ps1 | iex
```

What you should see first:

```
=== 1. Prerequisites
  +  Git 2.49.1.windows.1
  +  Node.js v24.20.0

=== 2. Patched MCP server
  -> cloning https://github.com/simoafdel-ctrl/Dynamics-365-Finance-Operations.git
  +  server sources in C:\d365fo-mcp-patched

=== 3. Handing over to the installer
```

Then `npm install` runs — **several minutes, with no output for long stretches.** That is normal
on a first install. Do not interrupt it.

### If the one-liner cannot run

Some machines block `irm | iex` by execution policy. Clone and run the script directly:

```powershell
git -c core.longpaths=true clone https://github.com/simoafdel-ctrl/Dynamics-365-Finance-Operations.git C:\d365fo-mcp-patched
C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1
```

If PowerShell refuses to run the script at all:

```powershell
powershell -ExecutionPolicy Bypass -File C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1
```

---

## Step 4 — Answer the three questions

Everything else is detected: the packages path, the model, the bridge binary, the available
label languages, the install folders. You will see the detected values scroll past first:

```
=== 2. D365FO environment
  +  packages path  K:\AosService\PackagesLocalDirectory
  +  model          ABC
  +  bridge         C:\Users\you\AppData\Local\d365fo-mcp\installation\bridge\D365MetadataBridge.exe
  +  74 label languages available in the metadata
```

Check that `model` is the one you expect **before** answering. Then:

| Question | How to answer |
|---|---|
| **Object prefix** | The team prefix for this client, e.g. `ABC_`. Trailing underscore optional — it is normalised either way. The default offered is the model name; accept it only if your prefix really is the model name. |
| **Label languages** | Primary first, comma separated: `en-US,fr-CA`. Validated against the languages actually present in the metadata, so a wrong locale is refused and near matches suggested. Ask the project lead if unsure — this ends up in every label you create. |
| **Projects folder** | Where you keep your D365FO solutions. The detected value is offered. Any drive is fine, including one other than `C:`. |

Press Enter to accept a default. If several custom models exist, a numbered list appears before
these questions — pick the one you work in.

---

## Step 5 — Wait out the metadata index

This is the long one, it runs by itself, and it is the step that makes the assistant able to
*find* anything. Nothing to answer — just do not close the window.

```
=== 6. Metadata index
  -> this runs once and takes 15-45 minutes on a full AOT - leave the window open
  -> [1/2] extracting metadata from the packages folder (XML -> JSON)
  -> [2/2] building the symbol database (JSON -> SQLite)
  +  index built
```

Two phases: every `.xml` in your packages folder is read out to JSON (~185 models, ~185 000
files), then loaded into a SQLite symbol database. The second phase prints a percentage per
model, largest first, so `Foundation` sitting at `[1%]` for a while is normal.

**Nothing else may hold the database while this runs.** The build needs exclusive access, so
close Claude Code and Visual Studio first — each one starts its own MCP server. The installer
checks and stops with that instruction rather than starting an hour of work it cannot finish.

On a re-run the installer finds the index already populated and skips straight past it. Two
switches change that:

| Switch | Effect |
|---|---|
| `-SkipIndex` | leave the index alone. Fast re-run when you only changed a team rule or a prefix. |
| `-ForceIndex` | rebuild it even though it has rows. Use after a platform update or a model import. |
| `-MetadataWorkPath <dir>` | put the extraction elsewhere. It defaults to the roomiest drive. |
| `-IndexPath <dir>` | put the 2–3 GB index elsewhere. An override already in your config is kept, never reset. |

The extraction folder is scratch space: it is only read by phase 2. You can delete it once the
install reports `[ OK ] symbol index is populated`, and the next `-ForceIndex` will write it again.

---

## Step 6 — Read the report

The install ends with a verdict, one line per check:

```
=== Report
  [ OK ] naming: CoC class extension
  [ OK ] naming: dot-notation extension
  [ OK ] bridge answers its ready handshake
  [ OK ] bridge has its dependencies
  [ OK ] symbol index is populated
  [ OK ] server entry point  dist\index.js
  [ OK ] metadata bridge     D365MetadataBridge.exe
  [ OK ] server config       d365fo-mcp.json
  [ OK ] client config       you\.mcp.json
  [ OK ] client config       repos\.mcp.json
  [ OK ] Claude Code         CLAUDE.md
  [ OK ] Copilot             copilot-instructions.md

  Environment
    model      : ABC
    prefix     : ABC_
    naming     : ABC_CustTable_Extension  |  CustTable.ABC
```

**Every line must read `[ OK ]`.** These are not cosmetic — they run the naming convention
against the freshly compiled code, start the real bridge binary against your real packages path,
and read the symbol database back.

| Line | What it means if it fails |
|---|---|
| `naming: …` | the convention is not active, or `dist` was not rebuilt — [see the naming section](TROUBLESHOOTING.md#the-naming-convention-is-not-applied) |
| `bridge answers …` | the bridge started but could not respond. Usually a wrong packages path — it needs the folder **containing** `bin\Microsoft.Dynamics.AX.Metadata.dll` — [see the bridge section](TROUBLESHOOTING.md#writes-fail-c-metadata-bridge-is-not-available) |
| `bridge has its dependencies` | the bridge was deployed without the DLLs it loads at runtime. It would start, log success, then die on its first answer — [see the bridge section](TROUBLESHOOTING.md#the-bridge-starts-then-dies-on-its-first-request) |
| `symbol index is populated` | the index is empty, so every search will come back empty — [see the index section](TROUBLESHOOTING.md#every-search-returns-nothing-and-even-standard-objects-are-not-found) |
| `client config …` | the `.mcp.json` is missing a key, or points at the unpatched npm package |
| any file line | that file did not land; the detail line under it gives the path |

Do not continue past a `[FAIL]`. The failing line names the section of
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) you need.

Everything the installer replaced was backed up first as `<name>.bak-<timestamp>`, so a re-run is
always safe.

---

## Step 7 — Connect the two clients

### Claude Code

```powershell
cd <your projects folder>
claude
```

The first time, Claude Code shows the local MCP server as **Pending approval** — approve it.
This happens once per machine.

Then verify it is really live. Ask Claude:

> *call get_workspace_info*

You want to see your `Model`, your `Prefix`, and `Env: traditional`. If the call fails the server
is not connected; if the answer opens with a configuration problem, read it — it states what is
wrong.

### Visual Studio / Copilot

Restart Visual Studio so Copilot rereads `%USERPROFILE%\.mcp.json`, then ask Copilot Chat the
same thing.

> Ignore the help paragraph of `get_workspace_info` if it describes an older naming style. That
> text is upstream prose the patch does not rewrite. It is cosmetic — **the setting line is what
> counts, and Step 8 is what proves it.**

---

## Step 8 — Prove the convention on disk

**Do not skip this.** It is the only step that proves the install rather than describing it. Two
different AI clients have reported the wrong extension name while the server was producing the
right one — an assistant describes what it expects, which is not always what happened.

Ask the assistant to create a CoC class extension on a table you do not care about, say
`CustTable`. Then look at what actually landed:

```powershell
Get-ChildItem 'K:\AosService\PackagesLocalDirectory\ABC\ABC' -Recurse -Filter '*CustTable*Extension*' |
  Select-Object Name, LastWriteTime
```

| You asked for | Correct file on disk |
|---|---|
| a CoC class extension of `CustTable` | `ABC_CustTable_Extension.xml` |
| a table extension of `CustTable` | `CustTable.ABC.xml` |

A doubled `ABC_CustTableABC_Extension` means the naming style is not active — go to
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#the-naming-convention-is-not-applied).

Delete the throwaway object once you have looked.

> Note: prefix and model are independent by design. A site with model `Abcco` and prefix `ABC_`
> correctly yields `ABC_CustTable_Extension` **and** `CustTable.Abcco`. That is not a bug.

---

## Step 9 — Before your first real task

Read [CONVENTIONS.md](CONVENTIONS.md) once. It is the short version of what the assistant is now
instructed to do, and what you should hold it to:

- **Naming is produced by the server.** Ask for `SalesLine`, not `ABC_SalesLine_Extension`.
- **Best practices are verified, never asserted.** If an assistant says an object "respects best
  practices" without having run `validate_code` and `xppbp`, do not believe it — ask for the
  check.
- **AOT objects go through the MCP tools only.** A text edit on `.xml`/`.xpp` corrupts the
  metadata model.
- **Writes apply immediately, with no preview.** The assistant describes the change and waits for
  your "ok"; `d365fo_file(action="undo")` reverts.
- **Builds are yours to trigger.** The assistant never compiles on its own — it would block your
  VM.

---

## If something goes wrong

1. Re-run the audit. It re-detects everything, runs both functional tests, and **writes nothing**:

   ```powershell
   C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1 -DryRun
   ```

2. Take the failing line to [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Every entry there is a
   failure hit on a real VM, listed under its literal symptom.

3. Two shortcuts worth knowing by heart:
   - **Writes suddenly fail after a VM restart** with `C# metadata bridge is not available` →
     it is the packages path, not the bridge binary. Check `D365FO_CUSTOM_PACKAGES_PATH` equals
     `D365FO_PACKAGE_PATH` in `.mcp.json`.
   - **`Filename too long` during the clone** → the target folder is too deep. Use
     `C:\d365fo-mcp-patched`.
   - **Every search comes back empty, even for a standard table** → the index was never built.
     Close your editors and run `Install-TeamMcp.ps1 -ForceIndex`.
   - **`database is locked` during the index** → an editor is still running its own MCP server.
     Close Claude Code and Visual Studio, then re-run.

---

## What gets installed where

| Path | What |
|---|---|
| `C:\d365fo-mcp-patched` | the patched server; `dist\index.js` is what the clients execute |
| `%LOCALAPPDATA%\d365fo-mcp\installation\config\d365fo-mcp.json` | server configuration |
| `%LOCALAPPDATA%\d365fo-mcp\installation\bridge\` | the C# metadata bridge, **with the DLLs it loads at runtime** |
| `%LOCALAPPDATA%\d365fo-mcp\installation\data\` | the symbol index — `xpp-metadata.db` (2–3 GB) and its labels database, unless `-IndexPath` moved it |
| `<roomiest drive>\d365fo-mcp-data\extracted-metadata\` | scratch output of the extraction; safe to delete after the install |
| `%USERPROFILE%\.mcp.json` | client configuration — Visual Studio / Copilot reads this |
| `<projects folder>\.mcp.json` | same content — Claude Code reads the one next to your work |
| `<projects folder>\CLAUDE.md` | rules for Claude Code, rendered with your prefix/model/languages |
| `<projects folder>\.github\copilot-instructions.md` | the same rules for Copilot |

Nothing is written to your D365FO metadata. The two `.mcp.json` are deliberate: Claude Code reads
the one in the folder you open, Copilot reads the one in your profile, and a workspace on another
drive never walks up to `%USERPROFILE%`.

## Re-running, and staying current

```powershell
git -C C:\d365fo-mcp-patched pull
C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1
```

This is how you pick up a changed team rule. A re-run leaves the existing index alone, so it
costs a minute, not an hour. Two cases where you do want to rebuild it:

- **after a platform or application update** — the AOT changed underneath the index,
- **after importing a model** — its objects are not in the index until it is rebuilt.

Both are `Install-TeamMcp.ps1 -ForceIndex`, with your editors closed.

The instruction files in your projects folder are
**generated** — edit the templates in the repository, never your local copy. A local edit is
overwritten on the next install and never reaches your colleagues.

## Unattended install

For setting up several machines, everything can be passed in:

```powershell
C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1 `
    -Prefix ABC_ -LabelLanguages en-US,fr-CA -WorkspacePath 'C:\Users\you\source\repos' -Yes
```

Add `-SkipIndex` when you are reconfiguring a machine whose index is already built, and the run
finishes in under a minute instead of waiting on the AOT.

`-Yes` takes every default and asks nothing. It refuses to guess where guessing would be wrong —
with several custom models and no `-Model`, it stops and tells you to name one.

---

## After a first install on a new machine

This install path is verified on a traditional VM, but a few branches only ever run on a genuinely
fresh box: the real `npm install` and build, compiling the bridge when no binary exists, the
interactive prompts, and UDE detection. If you are among the first to run it on a new VM, send the
team channel:

- the final report block (all the `[ OK ]` / `[FAIL]` lines),
- the file name produced in Step 8,
- how long the index step took, and which drive it extracted to,
- anything the installer asked that you found ambiguous.

That is what turns this from *tested* into *proven*.
