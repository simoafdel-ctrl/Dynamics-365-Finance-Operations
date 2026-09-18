# D365 Finance & Operations X++ Development

<!-- GENERATED FILE — do not hand-edit.
     Rendered by team/Install-TeamMcp.ps1 from team/templates/copilot-instructions.md on {{GENERATED_ON}}.
     Model: {{MODEL}} | Prefix: {{PREFIX}} | Label languages: {{LABEL_LANGUAGES_INLINE}}
     To change the team rules, edit the TEMPLATE in the repo and re-run the installer.

     Thin pointer — the full rules are delivered via the MCP `xpp_system_instructions` prompt.
     This file provides only the minimum static context needed when the MCP server
     is not yet connected or the prompt has not been loaded. Its Claude Code
     counterpart is CLAUDE.md at the root of this same workspace. -->

## Tool Priority

This workspace is served by a D365FO MCP server. **Always use the specialized MCP tools** for D365FO objects (`.xml`, `.xpp`, `.rnrproj`, `.label.txt`). Built-in file/search tools are fine for `.cs`, `.json`, `.yml`, `.md`, `.config` files.

## Mandatory First Check

Call `get_workspace_info()` before doing anything with D365FO objects.

| Response | Action |
|----------|--------|
| Call fails | STOP. MCP server not connected. Ask user to start it. |
| `CONFIGURATION PROBLEM` | STOP. Relay message. Wait for user. |
| Neither | Note the `Model` / `Prefix` / `EXTENSION_NAMING_STYLE` lines. Proceed. |

## Terminal Prohibition

PowerShell / any terminal command **WILL HANG** the MCP integration in Visual Studio 2022 / 2026. Never use `run_in_terminal` and never generate a script as a fallback when an MCP tool fails — STOP and report the error verbatim.

## Best-Practice Double-Check (MANDATORY — do not rely on your own judgment)

The MCP server already knows every D365FO best-practice rule and can check them mechanically. Your own memory of what an object "should" contain is unreliable — so DO NOT decide by hand whether labels, help text, or docs are present. Run the checker and let the tool tell you. This is a hard step of every write, not optional.

**Before every write — non-skippable:**
1. Call `validate_code(mode="both")` on the generated code. Runs the offline BP check (catches `BPErrorLabelIsText` — raw text where a label is required — missing labels/help text, and reference errors) in well under a second.
2. If it reports ANY error/warning about a missing label, missing help text, a raw-text string, or a missing doc, **fix it and re-run until clean** — then write. Never write an object that still has open `validate_code` findings.
3. Only then call `d365fo_file(action="create"/"modify")`.

**After writing a substantive object (table, EDT, class, form, security artifact):**
4. Run the full `xppbp` best-practice check — `build_d365fo_project(bpCheck: true)` or `run_bp_check(objects[])`. Slower (needs the compiler) so not for trivial edits, but for any real deliverable it is the authoritative confirmation that ALL best practices pass, not just the offline subset.
5. If it reports findings, fix via `d365fo_file(action="modify")` and re-run until clean. Report the final BP status in one line.

**Never** tell the user an object "respects best practices" from your own reading of it — that claim is valid only from a `validate_code` + `xppbp` result you actually ran. If you did not run the checker, say so instead of asserting compliance.

## Core Tool Mapping

| Action | Tool |
|--------|------|
| Plan an extension before changing code | `prepare(mode="change", goal, objectName, methodName?)` — returns signature, existing CoC wrappers, strategy + `groundingToken` |
| Plan a new object before creating it | `prepare(mode="create", goal, objectName, objectType)` — returns collision check, naming, EDT/label hints + `groundingToken` |
| Create a D365FO object | `d365fo_file(action="create")` (never `create_file`) |
| Edit an existing object | `d365fo_file(action="modify")` (applies immediately — confirm in chat first) |
| Revert the last write | `d365fo_file(action="undo", filePath)` — git-tracked -> checkout HEAD (discards ALL uncommitted changes to that file); untracked -> deleted |
| Search objects | `search` — multiple via `search(queries[])`, custom-only via `search(scope="extensions")` |
| Read any object metadata | `get_object_info(objectType, name, options?)` — objectType in class/table/form/query/view/enum/edt/report/data-entity/menu-item/service/map/config-key/security-policy/macro. 2+ known names: `get_object_info(objects=[{objectType,objectName},...])` — ONE call, never a loop |
| Method signature for CoC | `get_object_info(objectType="class", name, options={method, include:"signature"})` (already returned by `prepare(mode="change")`) |
| Validate X++ before write | `validate_code(mode="both", code)` — offline BP + reference check, <50 ms |
| X++ rules & patterns | `get_knowledge(kind="knowledge", topic)` — select grammar, CoC, BP rules, SysOperation, workflow, ... |
| Create a NEW form | `object_patterns(domain="form", action="analyze", recommend={...})` -> `object_patterns(domain="form", action="spec", pattern)` -> `generate_object(mode="scaffold", objectType="form", cloneFrom=referenceForm, tableMapping={...})` -> `object_patterns(domain="form", action="validate", xml)` |
| Validate form XML against its pattern | `object_patterns(domain="form", action="validate", xml \| formName \| filePath)` — structural errors block form writes (FORM_PATTERN_ENFORCE) |
| Resolve label / EDT / class refs | `validate_code(mode="references", code)` |
| Build / BP / Sync | `build_d365fo_project(bpCheck: true, dbSync: true)` — ONE call compiles, runs the best-practice check and syncs AxDB |
| Error diagnosis | `get_knowledge(kind="error", errorText)` |
| Parameters for a `d365fo_file` operation / `generate_object` mode | `get_knowledge(kind="op-spec", topic="add-index" \| "table" \| "scaffold:form")` — those two tools keep their parameters OUT of the tool schema; look the contract up once for the operation you picked, then nest the values in `params` (`properties` for `action="create"`) |

## Key Rules

### Workspace & model targeting

1. **The target model comes from `.mcp.json`** — never infer it from search results or object names. The symbol database contains objects from all models (Microsoft + ISV + custom); the model on a search/`get_*_info` result is the source model, not where new files belong.

### Writes & file editing

2. **`d365fo_file` (action=create/modify) applies immediately** (no dry-run / preview). Describe the change in chat and wait for explicit user confirmation ("apply", "ok", "yes") before calling. Revert with `d365fo_file(action="undo")` (or pass `createBackup=true` to keep a `.bak`).
3. **Never** use `replace_string_in_file`, `edit_file`, `apply_patch`, or any built-in file-write tool on `.xml` or `.xpp` files — **not even as a fallback** when `d365fo_file(action="modify")` fails. These bypass `IMetadataProvider` and corrupt the in-memory model of Visual Studio. If `d365fo_file(action="modify")` errors, STOP and report the error verbatim.

### Build automation

4. Never run `build_d365fo_project()` automatically — only on explicit user request ("build", "compile", "check errors"). (BP-check-only calls under the double-check section above are the exception when the user asked for a deliverable.)

### X++ correctness (BP-clean code)

5. Never copy default parameter values into CoC wrapper signatures.
6. Never use `today()` — use `DateTimeUtil::getToday(DateTimeUtil::getUserPreferredTimeZone())`.
7. Never use hardcoded strings in `Info()` / `warning()` / `error()` — use `@{{MODEL}}:LabelId` references.
8. Call `labels(action="search")` before `labels(action="create")` — reuse existing labels. This environment creates labels in **{{LABEL_LANGUAGES_INLINE}}**: always pass `languages: [{{LABEL_LANGUAGES_JSON}}]`.

### Documentation (team convention)

9. **XML doc comments are mandatory, in English, by default.** Every class and method authored or substantially modified carries `/// <summary>`, `/// <param>` per parameter, `/// <returns>` when it returns a value, and `/// <remarks>` when behavior is not self-evident (especially: name the standard object a CoC wrapper extends and why). Comments state *why*, never *what*. A missing doc is a `validate_code` finding to fix before writing.

### Extension naming — handled natively by the patched server

10. The server is patched with `EXTENSION_NAMING_STYLE=prefix-first` and produces the team convention **automatically**. Pass the BASE object name and let the server apply the style — do NOT hand-build names, do NOT override or re-inject the token. Expected results on this machine (prefix `{{PREFIX}}`, model `{{MODEL}}`):
    - CoC class extension -> `{Prefix}_{Base}_Extension` (e.g. `{{PREFIX_BARE}}_SalesFormLetter_Extension`) — prefix first, underscore-separated.
    - AOT element extension (table, form, security, menu, menu item, enum, EDT, data entity) -> `{Base}.{ModelName}` with NO "Extension" word (e.g. `SalesLine.{{MODEL}}`).
    - New non-extension object -> `{Prefix}_{Name}` (e.g. `{{PREFIX_BARE}}_MyNewEdt`).

    Prefix and model come from the workspace config, never from a feature, ticket, or customer name. Do NOT re-inject a prefix into a name that already carries it (that is what produces a `{{PREFIX_BARE}}_InventTable{{PREFIX_BARE}}_Extension` doubling). If a produced name is ever wrong, verify `EXTENSION_NAMING_STYLE=prefix-first` and `EXTENSION_PREFIX` are set — do not work around it by hand.

### Reuse & diff safety

11. **Reuse before creating** — `prepare(mode="change")` lists existing CoC wrappers and event handlers. If an extension or handler class in the custom model already owns the target, add the new method there. Never create a parallel feature-named class unless the user explicitly asks for a separate class.
12. **The post-write diff must be additive or narrowly targeted** — verify via `get_workspace_info(changes=true)` (or re-read with `get_object_info`) that no unrelated XML nodes (`<DataSources>`, `<Controls>`, methods, pattern metadata) disappeared. If they did, the edit failed: `d365fo_file(action="undo")`.
13. **An example form named by the user is a pattern contract** — keep its pattern family and required scaffolding (datasources, ActionPane/Tab/grid/QuickFilter); missing pattern elements are a failed generation even if the XML is well-formed.

### Spending tool calls

14. **Issue independent read-only calls together, in one step.** Every tool call re-reads the whole conversation, so a turn costs the round trip, not the tool. `get_object_info`, `search`, `labels`, `get_knowledge`, `object_patterns` and `find_references` have no side effects — five lookups are one step, not five.
15. **Use the plural form when there is one** — `get_object_info(objects[])`, `run_bp_check(objects[])`, `verify_d365fo_project(objects[])`, `search(queries[])`. All three `objects[]` forms take `{objectType, objectName}`; `queries[]` takes `{query}`. Note the SINGLE-object form of `get_object_info` still spells it `name`, not `objectName`.
16. **Plan the reads before the first one.** Decide which objects the change touches, then fetch them in a single step instead of discovering them one call at a time.

### Reading D365FO objects

17. **Use `get_object_info`, not `read_file`, for anything under `PackagesLocalDirectory`.** Raw AOT XML is verbose and stays in context; `get_object_info` returns the same facts structured and far smaller. Read the raw file only when you need its literal bytes.
18. **Never hand-edit AOT XML with text replacement** (rule 3) — whitespace and element ordering are load-bearing.
19. **Do not call `update_symbol_index` after `d365fo_file` create/modify** — the index is already refreshed. It is for files changed OUTSIDE the server. Sole exception: a brand-new AxEdt/AxEnum you are about to name in a `generate_object` `fieldsHint`.
20. **Ask for the smallest result set that answers the question** — `labels(action="search")` returns 10 one-line hits; raise `maxResults` or set `verbose` only when genuinely needed.

### Finishing

21. **Keep the closing summary to what changed and what to do next.** Long recaps are the most expensive single output of a session and are re-read by nothing.

## Full Instructions

The complete X++ rules, query grammar, CoC authoring rules, and workflow details are delivered via the MCP prompt `xpp_system_instructions`. If that prompt is not loaded, request it. Its source lives in the MCP server repository at `src/prompts/systemInstructions.ts`.
