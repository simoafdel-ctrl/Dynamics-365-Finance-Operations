# Architecture and design decisions

Why the installation is built the way it is. Read this before changing it — most of these
decisions are the scar tissue of a failure we do not want to repeat.

---

## The shape of it

```
C:\d365fo-mcp-patched\              clone of the internal fork (upstream 1.17.3 + our patch)
├─ install.ps1                      UPSTREAM's installer - installs from npm, NOT patched
├─ dist\index.js                    what the MCP clients actually execute
├─ prefix-first-naming-1.17.3.patch the standalone patch, for re-applying to a future upstream
└─ team\                            everything we own
   ├─ bootstrap.ps1                 one-liner entry point: clone/update -> build -> install
   ├─ Install-TeamMcp.ps1           detect -> ask -> validate -> write -> verify
   ├─ templates\                    generic instruction templates, {{TOKEN}} placeholders
   └─ docs\                         ONBOARDING, CONVENTIONS, TROUBLESHOOTING, this file

%LOCALAPPDATA%\d365fo-mcp\installation\
├─ config\d365fo-mcp.json           server configuration (generated)
├─ bridge\D365MetadataBridge.exe    C# metadata bridge
└─ extracted-metadata\              the index

<projects folder>\
├─ .mcp.json                        client config - the one Claude Code finds
├─ CLAUDE.md                        generated from team\templates
└─ .github\copilot-instructions.md  generated from team\templates
```

## Everything team-owned lives under `team/`

Two reasons, both practical.

**Upstream merges stay clean.** The fork is pinned at 1.17.3 and will eventually be moved
forward. Anything we add at the repository root, or to a file upstream also edits, becomes a
conflict on that day. Nothing upstream will ever touch `team/`, so the upgrade is a rebase with
no manual arbitration.

**The root `install.ps1` is upstream's and must not be confused with ours.** It installs the
`d365fo-mcp` package **from npm**, which does not carry the `prefix-first` patch. A dev who runs
it gets a server that looks installed, works, and silently produces the wrong names. Ours is
therefore not called `install.ps1` and does not live at the root. The installer also refuses to
configure a server without the patch marker, and its report fails when any `.mcp.json` points
anywhere other than the patched `dist\index.js`.

## The upstream `.github/copilot-instructions.md` is left alone

Upstream ships its own copy of that file, and it is not our adapted version. We keep our two
instruction files in `team/templates/` and let the installer deploy them into the developer's
projects folder.

Overwriting the upstream file instead would put our rules on a collision path with every future
upstream edit of the same file, for no benefit: the file that matters is the one in the
developer's workspace, not the one in the server repository.

## The repository stays generic, the installer renders

Templates carry `{{PREFIX}}`, `{{MODEL}}`, `{{LABEL_LANGUAGES_INLINE}}` and friends. The
installer substitutes each machine's detected values and fails loudly if any token survives
substitution.

This is what lets one repository serve every client engagement. Nothing project-specific,
customer-specific or machine-specific is ever committed — and the developer still receives an
instruction file that names *their* real prefix, model and label languages, instead of a generic
one they have to mentally translate.

The corollary: **generated files are not edited in place.** Every generated file carries a
header saying so. A local edit changes one machine, is overwritten on the next install, and never
reaches the team. Team rules change in the template.

## Detect, do not ask

Every question is a chance to enter a wrong value, and a wrong value in a config file is a
failure that surfaces hours later somewhere unrelated. So the installer asks three things and
derives the rest.

**The model is never typed.** The setup wizard we replaced once wrote `"modelName": "ABC_"` — the
*prefix* — on a site whose model was `Abcco`, and the resulting misbehaviour took a while to
trace back. The installer reads the model descriptors under the packages path, keeps those not
published by Microsoft, and requires `<packagePath>\<model>\<model>` to exist. With several
custom models it presents a numbered list; under `-Yes` it refuses to guess and asks for
`-Model`. On a re-run it keeps the model already configured. You cannot mistype a value you are
never asked for.

**The packages path is validated, not assumed.** A candidate counts only if
`bin\Microsoft.Dynamics.AX.Metadata.dll` sits inside it — which is exactly what the bridge needs
(see below).

**Label languages are validated against the metadata.** The installer enumerates the
`LabelResources` folders actually present and rejects anything else, suggesting near matches. That
turns the `FR` versus `fr-CA` mistake into a rejected answer rather than a config that produces
labels in the wrong language.

## Configuration is passed as environment variables, not left to the config file

Launched by a client from an arbitrary working directory, the server does not reliably apply the
values in `d365fo-mcp.json` — observed in the field: `Model name: (not configured)` and
`0 model(s)` while the file plainly held the right `modelName`.

So the `.mcp.json` passes everything explicitly: `D365FO_CONFIG`, `D365FO_PACKAGE_PATH`,
`D365FO_CUSTOM_PACKAGES_PATH`, `D365FO_MODEL_NAME`, `D365FO_BRIDGE_EXE_PATH`,
`EXTENSION_NAMING_STYLE`, `EXTENSION_PREFIX`, `EXTENSION_PREFIX_SOURCE`. The config file remains
the server's own reference; the environment is what we rely on.

### `D365FO_CUSTOM_PACKAGES_PATH` equals `D365FO_PACKAGE_PATH`, on purpose

This looks redundant and is the fix for the most expensive failure we have had — writes breaking
after a VM restart with `C# metadata bridge is not available`.

The bridge does `Path.Combine(packagesPath, "bin")` and needs the *platform* bin. The server can
resolve a custom packages path by XPP auto-detection, and that detection can land on the
solutions folder (`...\source\repos`) instead of `PackagesLocalDirectory`. The bridge then looks
for `...\source\repos\bin`, does not find it, and dies with
`[FATAL] D365FO bin path not found`.

The server reads `D365FO_CUSTOM_PACKAGES_PATH` **first**, which short-circuits that detection.
Because the value equals the packages path, the "custom path differs from the packages path"
condition is false and the server falls through to the correct path. The bridge gets what it
needs, deterministically, every boot. The installer's report fails if the two values ever drift
apart.

## Two locations, two keys

**Two locations** because the two clients look in different places, and a workspace on another
drive breaks the usual assumption. Claude Code reads the `.mcp.json` of the folder you opened,
walking up the tree; Copilot in Visual Studio reads the one in the user profile. A workspace at
`K:\Projects` never walks up to `C:\Users\you`, so the file is written to both.

**Two keys** because Claude Code reads `mcpServers` and Copilot reads `servers`. With only one
present the other client fails outright:
`[Failed to parse] mcpServers: Missing "mcpServers" - found "servers" instead.` Both keys carry
identical content.

The installer also rewrites the wizard leftover at
`%LOCALAPPDATA%\d365fo-mcp\installation\.mcp.json`, which points at the unpatched npm package.

## Files are written UTF-8 without BOM

A BOM in front of a JSON document breaks strict parsers, and configuration written by the
original wizard carries one. The PowerShell scripts themselves are pure ASCII with `[ OK ]` /
`[FAIL]` markers rather than symbols, because a UTF-8 script without BOM read by PowerShell 5.1
on a Windows Server console turns non-ASCII glyphs into mojibake. Colour carries the meaning.

## Idempotence and reversibility

Re-running the installer is the normal way to pick up a changed rule, so it must be boring.
Every replaced file is backed up as `<name>.bak-<timestamp>`; a file whose content is already
correct is reported `unchanged` and not touched; an already-configured machine keeps its model
without being asked again. `-DryRun` detects, validates and runs both functional tests while
writing nothing — it is the right first move when diagnosing a machine.

Nothing the installer writes touches D365FO metadata, so there is no AOT-side rollback.

## Why we verify on disk

Two different AI clients have reported the **wrong** extension name while the server was
producing the correct one, and one insisted seven times that the C# bridge needed rebuilding
while the binary sat there, present and functional — the only problem was a path.

An assistant describes what it expects, which is not always what happened. So the installer ends
with facts rather than assertions: the naming test imports the **compiled** `dist` module and
compares against the exact expected strings, and the bridge test starts the **real binary**
against the **real packages path** and looks for `MetadataProvider initialized successfully`.

The same discipline is asked of the developer in the onboarding: create one throwaway extension
and read the file name on disk. And of the assistant in the instruction files: best-practice
compliance is a checker result or it does not exist.

## Scope: traditional only

This installer supports **traditional** environments, meaning a local
`AosService\PackagesLocalDirectory`. A Unified Developer Environment is detected and refused with
a clear message rather than configured from a guess — a guessed configuration would fail later,
somewhere less obvious, and cost more than the refusal.

A UDE variant gets written when a real UDE box is available to test it against. Not before:
every value in here was verified on a real machine, and that is the property worth keeping.

## Updating from upstream

The fork is intentionally pinned at **1.17.3**. Move it only for a blocking bug, a wanted
feature or a security fix. To move it:

1. Clone the newer upstream version and re-apply `prefix-first-naming-1.17.3.patch`. If it no
   longer applies cleanly, port the logic to the four files it touches —
   `src/utils/modelClassifier.ts`, `src/utils/objectNamingRules.ts`, `src/config/settings.ts`,
   `tests/utils/objectNaming.test.ts`.
2. `npm install`, `npm run build`, run the test suite.
3. Re-run `team\Install-TeamMcp.ps1` on a real dev VM and require every report line to read
   `[ OK ]`.
4. Create one extension of each kind and check the names **on disk**.
5. Only then tell the team to pull.

`team/` should rebase without conflict. If it does not, something moved into upstream's
territory and belongs back under `team/`.
