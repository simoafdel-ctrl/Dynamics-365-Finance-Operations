# Onboarding — D365FO MCP server on your dev VM

This gets an AI assistant (Claude Code and/or GitHub Copilot in Visual Studio) working on
your D365FO dev VM with our team conventions already applied: naming, mandatory best-practice
checks, XML documentation, label languages.

Budget about 20 minutes, most of it waiting on `npm install` and the first metadata index.

Placeholders used below: `ABC_` is an object prefix, `ABC` a model name, `K:\` the drive
holding the AOS. Substitute what the installer detects on your own machine.

---

## Before you start

| Requirement | Check | If missing |
|---|---|---|
| Windows D365FO dev VM, **traditional** environment (a local `AosService\PackagesLocalDirectory`) | the folder exists on some drive | UDE is not supported yet — see [ARCHITECTURE.md](ARCHITECTURE.md#scope-traditional-only) |
| **Node.js 24+** | `node --version` | `winget install OpenJS.NodeJS.LTS`, then **reopen PowerShell** |
| **Git** | `git --version` | `winget install Git.Git`, then **reopen PowerShell** |
| A custom model exists in the environment | Visual Studio > Dynamics 365 > Model management | create it first, the installer needs somewhere to write |
| Visual Studio closed | — | the installer does not need it, but you will restart it at the end anyway |

Reopening PowerShell after installing Node or Git is not optional: the current session has a
stale `PATH` and the installer will not see the new tool.

---

## Install

One command in PowerShell:

```powershell
irm https://raw.githubusercontent.com/simoafdel-ctrl/Dynamics-365-Finance-Operations/main/team/bootstrap.ps1 | iex
```

It clones the patched server to `C:\d365fo-mcp-patched`, builds it, then runs the installer.

Already have the clone? Run the installer directly:

```powershell
C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1
```

### What it asks you — three questions, nothing else

Everything else is detected: the packages path, the model, the bridge binary, the available
label languages, the installation folders.

| Question | What to answer |
|---|---|
| **Object prefix** | Your team prefix for this client, e.g. `ABC_`. The trailing underscore is optional. Defaults to the model name. |
| **Label languages** | Primary first, comma separated, e.g. `en-US,fr-CA`. Validated against the languages actually present in the metadata, so a wrong locale (`FR` instead of `fr-CA`) is refused rather than written. |
| **Projects folder** | Where you keep your D365FO solutions. The detected value is offered; any drive is fine. |

### What it writes

| File | Why |
|---|---|
| `%LOCALAPPDATA%\d365fo-mcp\installation\config\d365fo-mcp.json` | server configuration: environment, model, naming, labels, bridge |
| `%USERPROFILE%\.mcp.json` | client configuration — Visual Studio / Copilot reads this one |
| `<projects folder>\.mcp.json` | same content — Claude Code reads the one next to your work |
| `<projects folder>\CLAUDE.md` | the rules Claude Code follows, rendered with your prefix/model/languages |
| `<projects folder>\.github\copilot-instructions.md` | the same rules for Copilot in Visual Studio |

Any file that already existed is backed up as `<name>.bak-<timestamp>` before being replaced.
Re-running the installer is safe.

The installer finishes with a file-by-file report, `[ OK ]` or `[FAIL]` per line, plus two
functional tests: the naming convention run against the compiled server, and the C# metadata
bridge starting against your packages path. **All lines must read `[ OK ]`.** If any says
`[FAIL]`, go to [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — the failing line names the problem.

---

## Finish, once each

### 1. Claude Code

```powershell
cd <your projects folder>
claude
```

Claude Code shows the local MCP server as **Pending approval** the first time — approve it.
Then check it is live:

> ask Claude: *call get_workspace_info*

You want to see your `Model`, your `Prefix`, and `Env: traditional`. If the call fails, the
server is not connected; if the answer starts with a configuration problem, read it — it says
what is wrong.

### 2. Visual Studio / Copilot

Restart Visual Studio so Copilot rereads `%USERPROFILE%\.mcp.json`. Then, in Copilot Chat,
ask it to call `get_workspace_info` too.

### 3. Prove the naming convention on something disposable

This is the one check nobody should skip, and the reason is in
[ARCHITECTURE.md](ARCHITECTURE.md#why-we-verify-on-disk): an assistant sometimes *describes*
the old naming style from memory while the server produces the correct one. Only the file on
disk is authoritative.

Ask the assistant to create a class extension on a table you do not care about, then look at
what actually landed:

```powershell
Get-ChildItem 'K:\AosService\PackagesLocalDirectory\ABC\ABC' -Recurse -Filter '*CustTable*Extension*'
```

Expected, with prefix `ABC_` and model `ABC`:

| You asked for | File on disk |
|---|---|
| a CoC class extension of `CustTable` | `ABC_CustTable_Extension.xml` |
| a table extension of `CustTable` | `CustTable.ABC.xml` |

Anything else — in particular a doubled `ABC_CustTableABC_Extension` — means the naming style
is not active. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#the-naming-convention-is-not-applied).

Delete the throwaway object afterwards.

---

## How to work with it, in one page

Read [CONVENTIONS.md](CONVENTIONS.md) once — it is the short version of what the assistant is
now instructed to do, and what you should expect from it:

- Naming is produced by the server. Ask for `SalesLine`, not `ABC_SalesLine_Extension`.
- Best practices are **verified by running the checker**, never asserted from reading code.
  If an assistant tells you an object "respects best practices" without having run
  `validate_code` and `xppbp`, do not believe it.
- AOT objects (`.xml`, `.xpp`) are written through the MCP tools only. A text edit on AOT XML
  corrupts the metadata model.
- Writes apply immediately, with no preview. The assistant must describe the change and wait
  for your "ok" — and it can revert with `d365fo_file(action="undo")`.
- Builds are yours to trigger. The assistant never compiles on its own, because that blocks
  your VM.

## Keeping up to date

```powershell
git -C C:\d365fo-mcp-patched pull
C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1
```

Re-running the installer is how you pick up an updated rule: the instruction files in your
projects folder are **generated**, so edit the templates in the repo, not your local copy.
A local edit is overwritten on the next install and never reaches your colleagues.

## Audit a machine without changing it

```powershell
C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1 -DryRun
```

Detects, validates, runs both functional tests, writes nothing. This is the right first move
when something stops working.
