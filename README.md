# D365FO MCP Server — patched (prefix-first naming)

Fork of [dynamics365ninja/d365fo-mcp-server](https://github.com/dynamics365ninja/d365fo-mcp-server)
**v1.17.3**, patched with a configurable team extension-naming convention.

Every value shown below (`ABC`, `ABC_`, `XYZ`) is a **placeholder**. The real prefix and
model name are read from each machine's configuration at runtime — nothing is hard-coded,
so one single build serves every environment.

---

## What the patch adds

The upstream server ships two extension-naming styles (`prefix`, `model-name`). This fork
adds a third value for the `EXTENSION_NAMING_STYLE` setting: **`prefix-first`**.

When `prefix-first` is active, the server names objects like this — automatically, with no
manual naming and no token injection to override:

| Object kind | Produced name | Example (prefix `ABC_`, model `ABC`) |
|-------------|---------------|--------------------------------------|
| CoC class extension | `{Prefix}_{Base}_Extension` — prefix first, underscore-separated | `ABC_SalesFormLetter_Extension` |
| AOT element extension (table, form, security, menu, menu item, enum, EDT, data entity) | `{Base}.{ModelName}` — the model name after the dot, **no** "Extension" word (this is what Visual Studio generates natively) | `SalesLine.ABC` |
| New non-extension object (EDT, form, class, menu item…) | `{Prefix}_{Name}` | `ABC_SomeNewObject` |

### Two independent tokens
The convention deliberately uses **two different sources**:
- **CoC classes** and **new objects** take the **object prefix** (`naming.prefix`, e.g. `ABC_`).
- **Dot-notation extensions** take the **model name** (`workspace.modelName`), matching the
  Visual Studio default.

These are usually the same, but not always. If a site's model is named differently from its
object prefix — say model `XYZ` with prefix `ABC_` — then a CoC class becomes
`ABC_SalesLine_Extension` while a table extension becomes `SalesLine.XYZ`. Both are handled
correctly and independently.

### Idempotent (safe to re-run)
Re-normalising a name that is already correct is a no-op. This means:
- No double-prefix: passing an already-prefixed name never yields `ABC_SalesLineABC_Extension`.
- Migration: a stale `SalesLine.ABCExtension` left by the old `prefix` style is converted to
  the clean `SalesLine.ABC`.

This is what prevents the duplicate/parallel extension objects that the default style could
otherwise create.

---

## Files changed by the patch
- `src/utils/modelClassifier.ts` — the naming logic (`getExtensionNamingStyle`, `applyObjectPrefix`).
- `src/utils/objectNamingRules.ts` — the validator, so it expects and suggests the new names.
- `src/config/settings.ts` — exposes `prefix-first` as an install-time choice.
- `tests/utils/objectNaming.test.ts` — tests covering the convention and idempotence.

`prefix-first-naming-1.17.3.patch` at the repo root is the standalone patch, kept so the same
change can be re-applied to a future upstream version.

---

## Install on a new dev VM

Prerequisites: **Node.js 18+** and **Git**.

```powershell
git clone https://github.com/simoafdel-ctrl/Dynamics-365-Finance-Operations.git C:\d365fo-mcp-patched
cd C:\d365fo-mcp-patched
npm install
npm run build
```

`npm run build` regenerates the `dist/` folder — that is what the MCP clients actually run.
Then configure the server for the environment (below) and point the clients at
`C:\d365fo-mcp-patched\dist\index.js`.

---

## Configuration per environment

Replace `<PREFIX_>` and `<MODEL>` with the values of the environment you are installing on.

### 1. Server config (`d365fo-mcp.json`)
This is the file the client passes to the server via the `D365FO_CONFIG` variable. The naming
section must contain:

```json
"naming": {
  "prefix": "<PREFIX_>",
  "prefixSource": "config",
  "extensionStyle": "prefix-first"
}
```
- `prefix` — the object prefix, e.g. `ABC_` (keep the trailing underscore).
- `prefixSource: "config"` — forces the server to use that prefix as-is, instead of trying to
  infer one from existing objects.
- `extensionStyle: "prefix-first"` — activates this fork's convention.

### 2. Client config (`C:\Users\<user>\.mcp.json`)
A single file serves **both** clients. Claude Code reads the `mcpServers` key; GitHub Copilot
(in Visual Studio) reads the `servers` key. Put both, pointing at the same patched server, and
pass the naming variables directly in `env` (most reliable — it does not depend on how the
server reads its config file):

```json
{
  "servers": {
    "d365fo-mcp-tools": {
      "command": "node",
      "args": ["C:\\d365fo-mcp-patched\\dist\\index.js"],
      "env": {
        "D365FO_CONFIG": "<path to d365fo-mcp.json>",
        "EXTENSION_NAMING_STYLE": "prefix-first",
        "EXTENSION_PREFIX": "<PREFIX_>",
        "EXTENSION_PREFIX_SOURCE": "config"
      }
    }
  },
  "mcpServers": {
    "d365fo-mcp-tools": {
      "command": "node",
      "args": ["C:\\d365fo-mcp-patched\\dist\\index.js"],
      "env": {
        "D365FO_CONFIG": "<path to d365fo-mcp.json>",
        "EXTENSION_NAMING_STYLE": "prefix-first",
        "EXTENSION_PREFIX": "<PREFIX_>",
        "EXTENSION_PREFIX_SOURCE": "config"
      }
    }
  }
}
```

Both keys point at the same `dist\index.js`, so both clients produce the identical convention.

---

## Verify the install (test the fact, not the description)

Run the real compiled code with the environment's values:

```powershell
$env:EXTENSION_NAMING_STYLE="prefix-first"; $env:EXTENSION_PREFIX="<PREFIX_>"; $env:EXTENSION_PREFIX_SOURCE="config"
node -e "import('file:///C:/d365fo-mcp-patched/dist/utils/objectNaming.js').then(m => { console.log(m.normalizeObjectName('CustTable','class-extension','<MODEL>',()=>{})); console.log(m.normalizeObjectName('CustTable','table-extension','<MODEL>',()=>{})); })"
```
Expected output: `<PREFIX>_CustTable_Extension` on the first line, `CustTable.<MODEL>` on the second.

Then create one real extension through a client and check the **file name written to disk** —
not what the assistant says. The AI clients sometimes *describe* the old naming style from
memory even when the server produces the correct one; only the created file is authoritative.

---

## Updating from upstream

This fork is intentionally pinned at **v1.17.3**. Update only when there is a real reason: a
blocking bug, a wanted new feature, or a security fix. To update: clone the newer upstream
version, re-apply the patch (or re-apply its logic to the four files listed above if the patch
no longer applies cleanly), rebuild, and re-test.

## Test status
The full upstream test suite passes (6000+ tests). The single failing test
`publishedFiles.test.ts` also fails on a clean upstream clone — it is a packaging/clone
artefact, unrelated to this patch.
