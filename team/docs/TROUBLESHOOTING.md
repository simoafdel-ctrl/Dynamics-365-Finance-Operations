# Troubleshooting

Every entry here was hit on a real dev VM. The symptoms are the literal messages you will see.

Placeholders: `ABC_` a prefix, `ABC` a model, `K:\AosService\PackagesLocalDirectory` a packages
path. Substitute your own.

**First move, always:**

```powershell
C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1 -DryRun
```

It re-detects everything, runs the naming test and the bridge test, and writes nothing. Most of
the time the failing line tells you which section below you need.

---

## Writes fail: "C# metadata bridge is not available"

**Symptom, from the assistant:**

```
Error modifying D365FO file: C# metadata bridge is not available.
```

**Symptom, from the bridge itself:**

```
[FATAL] D365FO bin path not found: bin
```

This is the most expensive failure we have had, and it usually appears **after a VM restart**
on an installation that worked yesterday.

**Read the FATAL line carefully.** `bin` alone, with no folder in front of it, means the
packages path handed to the bridge was **empty**. A wrong path shows as
`[FATAL] D365FO bin path not found: C:\Users\you\source\repos\bin`.

**Root cause.** The bridge does `Path.Combine(packagesPath, "bin")` and needs the *platform*
bin — the one holding `Microsoft.Dynamics.AX.Metadata.dll` — not a project `bin` under your
solutions folder. The server can resolve a custom packages path through XPP auto-detection,
and after a restart that detection sometimes lands on the solutions folder instead of
`PackagesLocalDirectory`. The bridge then looks for `<solutions>\bin`, which does not exist.

**Fix.** `D365FO_CUSTOM_PACKAGES_PATH` must be present in `.mcp.json` and **equal** to
`D365FO_PACKAGE_PATH`. The server reads that variable first, which short-circuits the faulty
auto-detection; because the value equals the packages path, it then falls through to the
correct path and the bridge gets what it needs.

```powershell
# what it must look like, in BOTH .mcp.json files
"D365FO_PACKAGE_PATH":         "K:\\AosService\\PackagesLocalDirectory",
"D365FO_CUSTOM_PACKAGES_PATH": "K:\\AosService\\PackagesLocalDirectory",
```

Re-running `Install-TeamMcp.ps1` writes both, and its report fails the client-config line if
the two ever differ.

**Prove the bridge is fine, before suspecting anything else:**

```powershell
& "$env:LOCALAPPDATA\d365fo-mcp\installation\bridge\D365MetadataBridge.exe" `
    --packages-path "K:\AosService\PackagesLocalDirectory"
```

Expected — and the **last** lines are the ones that matter:

```
[INFO] MetadataProvider initialized successfully
{"id":"ready","result":{"version":"1.0.0","status":"ready","metadataAvailable":true, ... }}
[INFO] Bridge ready, entering stdin/stdout loop
```

`MetadataProvider initialized successfully` **on its own proves nothing.** It is printed before
the bridge serialises a single byte, so a bridge that is one instruction away from crashing
prints it too. Only the `{"id":"ready"}` line means the bridge can answer. If the output stops
at the INFO line, go to [the next section](#the-bridge-starts-then-dies-on-its-first-request).

**Do not conclude "the bridge is not compiled".** The binary is almost always already there.
On one incident an assistant insisted seven times on rebuilding the bridge project while the
binary was present and working — the only problem was the path. The deployed bridge lives in
exactly one place:

```powershell
"$env:LOCALAPPDATA\d365fo-mcp\installation\bridge\D365MetadataBridge.exe"
```

If that is missing, re-run `Install-TeamMcp.ps1`: it deploys the bridge together with the DLLs
it loads at runtime. Do **not** go hunting for a `D365MetadataBridge.exe` inside the clone and
point `bridge.exePath` at what you find — the copy under `bridge\D365MetadataBridge\obj\` is an
intermediate build output with no dependencies next to it, and using it causes exactly the
failure in the next section. `npm run bridge:build` does not help either: it is a compile check
that builds into a temp folder and deliberately leaves the deployed binary alone.

---

## The bridge starts, then dies on its first request

**Symptom, from the assistant:** the same `C# metadata bridge is not available` /
`The C# bridge is not connected` as above — but the packages path is correct and
`D365FO_CUSTOM_PACKAGES_PATH` already equals `D365FO_PACKAGE_PATH`, so the section above does
not apply.

**Symptom, running the bridge by hand:** it gets all the way through metadata initialisation
and then throws instead of printing its handshake.

```
[INFO] MetadataProvider initialized successfully
[INFO] MetadataWriteService initialized

Unhandled Exception: System.IO.FileNotFoundException: Could not load file or assembly
'System.Threading.Tasks.Extensions, Version=4.2.0.1, ...' or one of its dependencies.
   at System.Text.Json.JsonSerializer.SerializeToElement[TValue](...)
   at D365MetadataBridge.Program.<RunBridge>...
```

**Root cause.** The bridge is running from a folder that does not contain the DLLs it loads at
runtime — almost always `bridge\D365MetadataBridge\obj\Release\`, the *intermediate* build
output. That folder holds the compiled assembly and nothing else. Assembly resolution falls
back to the D365FO platform `bin`, which is enough to bring up the MetadataProvider, so the
bridge logs success — and then dies the moment `System.Text.Json` needs a dependency the
platform `bin` does not carry, which happens on the very first response it tries to serialise.

A bridge in this state passes a naive health check and fails every real call.

**Fix.** Deploy it properly, which is what a re-run of the installer now does:

```powershell
C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1
```

To do it by hand, build into the deployment folder so the dependencies are copied next to the
exe, then point the configuration at that copy:

```powershell
dotnet build C:\d365fo-mcp-patched\bridge\D365MetadataBridge -c Release --no-incremental `
    -o "$env:LOCALAPPDATA\d365fo-mcp\installation\bridge"
```

**Verify the deployment rather than the exe.** One file tells the two layouts apart:

```powershell
Test-Path "$env:LOCALAPPDATA\d365fo-mcp\installation\bridge\System.Threading.Tasks.Extensions.dll"
```

`False` means the bridge cannot answer, whatever else looks right. Then re-run the bridge by
hand and require the `{"id":"ready"}` line.

---

## Every search returns nothing, and even standard objects are not found

**Symptom, from the assistant:**

```
No X++ symbols found matching "VendBankAccount"
```

```
Table "VendBankAccount" not found via bridge, symbol index, or on disk.
```

```
No custom/ISV models are known to the index, so scope="extensions" can never match.
```

`get_workspace_info` answers normally and reports your model and prefix, which is what makes
this one confusing: nothing looks broken. A standard table that obviously exists cannot be
found, and the index reports `no freshness timestamp yet`.

**Root cause.** The symbol index was never built. The database file exists and has its full
schema — so nothing errors — and every one of its tables has zero rows. An empty index is
indistinguishable from a healthy one until you search.

**Confirm it in one command.** `0` here is the whole diagnosis:

```powershell
node -e "const {DatabaseSync}=require('node:sqlite'); const p=process.env.LOCALAPPDATA+'/d365fo-mcp/installation/data/xpp-metadata.db'; console.log(new DatabaseSync(p,{readOnly:true}).prepare('SELECT COUNT(*) c FROM symbols').get().c)"
```

A healthy full-AOT index answers with over a million symbols and the file is 2–3 GB.

**Fix.** Close Claude Code and Visual Studio — each runs its own MCP server, and the build needs
exclusive access to the database — then:

```powershell
C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1 -ForceIndex
```

Reopen your editor afterwards. The server reads the index at startup, so a server that was
running while the index was built still has the empty one open.

### `database is locked` during the index

```
✗ Fatal error: database is locked
    at Database.pragma (src/database/sqlite.ts:122)
```

An MCP server still holds the file. `build-database` switches the journal to MEMORY, and SQLite
refuses that while any other connection is attached — even an idle reader in another process.
Close every editor that starts a server and re-run. To find what is holding it:

```powershell
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Select-Object ProcessId, CommandLine
```

Anything running `d365fo-mcp-patched\dist\index.js` is a server. Note that `BEGIN EXCLUSIVE`
succeeding is not proof the file is free — the journal switch is a stricter condition.

---

## The naming convention is not applied

**Symptom:** you get `CustTableABC_Extension`, or a doubled `ABC_CustTableABC_Extension`,
instead of `ABC_CustTable_Extension`.

Check, in order:

1. **`EXTENSION_NAMING_STYLE` is `prefix-first` in `.mcp.json`**, in both the `servers` and
   `mcpServers` blocks, together with `EXTENSION_PREFIX` and `EXTENSION_PREFIX_SOURCE=config`.
2. **The client points at the patched server.** `args[0]` must be
   `C:\d365fo-mcp-patched\dist\index.js`. If it points anywhere under
   `AppData\Roaming\npm\node_modules\d365fo-mcp`, you are running the **vanilla package from
   npm**, which has no `prefix-first` style — naming silently falls back to the default and
   nothing warns you. See [the npm trap](#i-am-running-the-unpatched-server-without-knowing-it).
3. **Test the compiled code directly**, which removes every client from the equation:

```powershell
$env:EXTENSION_NAMING_STYLE='prefix-first'; $env:EXTENSION_PREFIX='ABC_'; $env:EXTENSION_PREFIX_SOURCE='config'
node -e "import('file:///C:/d365fo-mcp-patched/dist/utils/objectNaming.js').then(m => { console.log(m.normalizeObjectName('CustTable','class-extension','ABC',()=>{})); console.log(m.normalizeObjectName('CustTable','table-extension','ABC',()=>{})); })"
```

Expected: `ABC_CustTable_Extension` then `CustTable.ABC`. If this is correct but the created
file is not, the problem is the client configuration, not the server.

4. **Did you rebuild after pulling?** `dist/` is what the clients execute, not `src/`.
   `npm run build`, or just re-run the installer, which rebuilds when `dist` is stale.

### The tool help text contradicts the setting

`get_workspace_info` correctly reports `EXTENSION_NAMING_STYLE: prefix-first` while its
explanatory paragraph still describes the old style (`CustTableAbc_Extension`). That text is
static upstream prose the patch does not rewrite. It is cosmetic.

**Never validate naming from a description** — not from the tool help, not from what an
assistant tells you it did. Only the file written on disk counts:

```powershell
Get-ChildItem 'K:\AosService\PackagesLocalDirectory\ABC\ABC' -Recurse -Filter '*CustTable*Extension*'
```

---

## I am running the unpatched server without knowing it

The package `d365fo-mcp` on npm is upstream, with no `prefix-first`. Two ways it sneaks in:

- Running the **`install.ps1` at the root of this repository** — that is upstream's own
  installer and it installs from npm. Use `team\bootstrap.ps1` or `team\Install-TeamMcp.ps1`.
- A leftover `.mcp.json` from the setup wizard at
  `%LOCALAPPDATA%\d365fo-mcp\installation\.mcp.json`, whose `args` point at
  `AppData\Roaming\npm\node_modules\d365fo-mcp\dist\index.js`.

The installer rewrites that leftover file and its report fails if any `.mcp.json` points
somewhere other than the patched `dist\index.js`. To check by hand:

```powershell
(Get-Content "$env:USERPROFILE\.mcp.json" -Raw | ConvertFrom-Json).mcpServers.'d365fo-mcp-tools'.args
```

---

## The MCP server does not appear in the client

### Claude Code

- `Pending approval (run 'claude' to approve)` — expected on first use. Run `claude` in your
  projects folder and approve the local server. Once.
- Nothing at all: Claude Code reads the `.mcp.json` of the folder you opened, walking up the
  tree. If your work lives on `K:\Projects` and the only `.mcp.json` is in
  `C:\Users\you`, it will **never** be found — different drive, no common parent. This is why
  the installer writes both locations. Confirm one sits in the folder you actually open.

### Copilot in Visual Studio

- Restart Visual Studio after any `.mcp.json` change.
- `[Failed to parse] mcpServers: Missing "mcpServers" - found "servers" instead.`
  The file has only one of the two keys. Claude Code reads `mcpServers`, Copilot reads
  `servers`; both must be present with identical content. Re-run the installer.

---

## Model name empty, or zero models

**Symptom:** `Model name: (not configured)`, or `0 model(s)`, while `d365fo-mcp.json` clearly
contains the right `modelName`.

Launched by a client from an arbitrary working folder, the server does not reliably apply the
values from its config file. This is why every key value is **also** passed as an environment
variable in `.mcp.json` — `D365FO_MODEL_NAME`, `D365FO_PACKAGE_PATH`,
`D365FO_CUSTOM_PACKAGES_PATH`, `D365FO_CONFIG`, `D365FO_BRIDGE_EXE_PATH`. Do not rely on the
config file alone. Re-run the installer, restart the client.

## The model is wrong: the prefix ended up in the model field

**Symptom:** `"modelName": "ABC_"` where the real model is `Abcco`.

The interactive `npm run setup` wizard can fill the model field with the prefix. Our installer
never asks for the model — it reads the model descriptors under the packages path, keeps the
ones not published by Microsoft, and checks that `<packagePath>\<model>\<model>` exists. You
cannot mistype a value you are not asked for.

If the environment has several custom models, the installer lists them and you pick one; it
refuses to guess under `-Yes` and tells you to pass `-Model`. On a re-run it keeps the model
already configured, so you never have to repeat it.

Note that prefix and model are **independent**. A site with model `Abcco` and prefix `ABC_`
correctly produces `ABC_SalesLine_Extension` *and* `SalesLine.Abcco`. That is not a bug.

---

## Labels are created in the wrong language

Label languages vary per client (`fr-CA` on one site, another locale elsewhere). The installer
validates your answer against the languages actually present in the metadata and suggests the
near matches, so `FR` is rejected in favour of `fr-CA` before it reaches any config.

The chosen languages land in two places: `index.labelLanguages` in `d365fo-mcp.json`, and the
rendered `CLAUDE.md` / `copilot-instructions.md`, which instruct the assistant to pass exactly
those languages to `labels(action="create")`. If an assistant creates a label in one language
only, check that your instruction files are the generated ones and not a stale hand-edited copy
— the header of a generated file says so.

---

## The clone fails: "Filename too long"

**Symptom, during `git clone`:**

```
error: unable to create file eval/goldens/.../SomeVeryLongName.metadata.xml: Filename too long
fatal: unable to checkout working tree
warning: Clone succeeded, but checkout failed.
```

Windows caps a path at 260 characters and this repository carries deep paths under
`eval/goldens/`. The clone then leaves a folder that **has a `.git` but no working tree** — it
looks cloned and nothing works.

`team/bootstrap.ps1` clones with `-c core.longpaths=true`, which uses the long-path API and
avoids this entirely, and it deletes the incomplete folder if a clone fails so a retry starts
clean. You only meet this by cloning by hand. If you do:

```powershell
git -c core.longpaths=true clone https://github.com/simoafdel-ctrl/Dynamics-365-Finance-Operations.git C:\d365fo-mcp-patched
```

Keep the target folder short — `C:\d365fo-mcp-patched` is the standard and leaves plenty of
headroom. A deep folder (a nested temp or profile path) eats the budget before git starts.

### Deleting such a folder also fails

`Remove-Item -Recurse -Force` hits the same 260-character wall: it deletes everything except
the deep files and leaves a folder behind that blocks the next attempt. Use robocopy, which
speaks long paths natively — mirror an empty folder over it, then delete:

```powershell
$empty = New-Item -ItemType Directory -Path "$env:TEMP\empty-mirror" -Force
robocopy $empty.FullName 'C:\path\to\the\broken\clone' /MIR | Out-Null
Remove-Item 'C:\path\to\the\broken\clone' -Recurse -Force
Remove-Item $empty -Recurse -Force
```

## The PowerShell window closes at the end, and the report is never seen

**Symptom:** the install runs its full course, the index is built, and the window disappears on
its own right at the end — no `=== Report`, no `Install complete`.

`irm | iex` does not run `bootstrap.ps1` as a script: it runs its text inside your own
PowerShell session. An `exit` in that text therefore closes the session, and older versions of
the bootstrap ended with one. The report was printed and the window closed a millisecond later;
a `BOOTSTRAP STOPPED` message vanished the same way.

The current bootstrap has no `exit` on that path, so the window stays open on the report,
whether it passed or failed. `irm | iex` always fetches the latest bootstrap, so the next run
gets the fix. To read the verdict of an install that already ran, run the installer again and
press Enter at the three questions to keep your answers. It finds the build, the bridge and the
index in place, skips them, rewrites nothing that is unchanged, and ends on the full report in a
couple of minutes:

```powershell
C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1
```

After an install, `$LASTEXITCODE` holds the result: `0` all checks passed, `1` something failed
or stopped.

## npm install or npm run build fails

- **`npm` is not recognised.** Node was installed in another session. Close and reopen
  PowerShell so `PATH` refreshes.
- **Node too old.** The server requires **Node 24+** (`engines` in `package.json`), not 18.
  `node --version`, then install a current LTS.
- **A test fails: `publishedFiles.test.ts`.** Known, and it fails on a clean upstream clone
  too — a packaging artefact of cloning rather than installing from the registry. Unrelated to
  the patch, and it does not affect the build.

---

## Undo an install

To remove the installation altogether, use the uninstaller rather than deleting folders by hand
— it finds an index that was moved off the default drive, and it unregisters the server without
throwing away any other MCP server in your `.mcp.json`:

```powershell
C:\d365fo-mcp-patched\team\Uninstall-TeamMcp.ps1 -DryRun   # the plan
C:\d365fo-mcp-patched\team\Uninstall-TeamMcp.ps1           # with your editors closed
```

See [ONBOARDING.md](ONBOARDING.md#removing-it-again) for the switches, notably `-KeepIndex` when
you intend to reinstall.

To roll back a **re-install** instead, every file the installer replaced is backed up next to
itself as `<name>.bak-<timestamp>`. Restore the ones you care about:

```powershell
Get-ChildItem "$env:USERPROFILE\.mcp.json.bak-*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
# then
Copy-Item '<that file>' "$env:USERPROFILE\.mcp.json" -Force
```

The same applies to `d365fo-mcp.json`, `CLAUDE.md` and `.github\copilot-instructions.md`.
Nothing the installer writes touches your D365FO metadata, so there is nothing to undo on the
AOT side.

---

## Still stuck

Collect this and bring it to the team channel:

```powershell
C:\d365fo-mcp-patched\team\Install-TeamMcp.ps1 -DryRun        # full report
node --version; git --version
Get-Content "$env:USERPROFILE\.mcp.json" -Raw                  # redact nothing, there are no secrets in it
```

Then say what you asked the assistant for, and what name actually appeared on disk. Those two
facts resolve most reports on their own.
