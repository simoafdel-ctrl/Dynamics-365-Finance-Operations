# CLAUDE.md — D365 F&O X++ (Claude Code)

<!-- GENERATED FILE — do not hand-edit.
     Rendered by team/Install-TeamMcp.ps1 from team/templates/CLAUDE.md on {{GENERATED_ON}}.
     Model: {{MODEL}} | Prefix: {{PREFIX}} | Label languages: {{LABEL_LANGUAGES_INLINE}}
     To change the team rules, edit the TEMPLATE in the repo and re-run the installer —
     edits made here are lost on the next install and never reach your colleagues. -->

Static instruction layer for Claude Code operating on this D365FO workspace. This file is a **thin mirror** of the MCP prompt `xpp_system_instructions`, which is the source of truth. It carries only: the operational mechanics needed before that prompt is loaded, the client-specific adaptations, and the local conventions the server does not know. **Rules about X++ code itself live in `get_knowledge` — query it, do not restate it here.**

Runtime context: Claude Code on a Windows D365FO dev VM (server `full` mode + C# bridge), with **Visual Studio open alongside** for the AOT designer, compilation and execution.

---

## Source of truth

1. **`xpp_system_instructions`** (MCP prompt) — tool decision tree + hard prohibitions. If it is not loaded, request it before generating any X++.
2. **`get_knowledge(kind="knowledge", topic)`** — all rules *about code*: select grammar, CoC authoring, SysOperation, number sequences, BP rules, security, AX2012->D365FO migration. Consult the relevant topic BEFORE generating; never answer X++ semantics from training data.
3. This file — mechanics, client adaptations, local conventions only.

---

## Mandatory first check

Call `get_workspace_info()` before doing anything with D365FO objects.

| Response | Action |
|----------|--------|
| Call fails | STOP. MCP server not connected. Ask the user to start it. |
| `CONFIGURATION PROBLEM` | STOP. Relay the message verbatim. Wait. |
| Neither | Note the `Model` / `Prefix` / `EXTENSION_NAMING_STYLE` lines. Proceed. |

Always use the specialized MCP tools for D365FO objects (`.xml`, `.xpp`, `.rnrproj`, `.label.txt`). Built-in file/search tools are fine for `.cs`, `.json`, `.yml`, `.md`, `.config`.

---

## Grounded workflows (from `xpp_system_instructions` — do not skip a step)

- **Extend existing object** -> `prepare(mode="change")` -> generate -> `validate_code(mode="both")` -> confirm in chat -> `d365fo_file(action="modify")`
- **New object** -> `prepare(mode="create")` -> generate -> `validate_code(mode="both")` -> `d365fo_file(action="create")`
- **New form** -> `object_patterns(domain="form", action="analyze")` -> `..."spec"` -> `generate_object(mode="scaffold", objectType="form", cloneFrom)` -> `object_patterns(domain="form", action="validate")` -> `d365fo_file(action="create")`

The grounding token from `prepare` is bound to its object; the write tools reject a token issued for a different one. Never hand-write form XML — a user-named example form is a pattern contract, not inspiration.

---

## Best-practice double-check (MANDATORY — do not rely on your own judgment)

The MCP server already knows every D365FO best-practice rule and can check them mechanically. Your own memory of what an object "should" contain is unreliable, especially on smaller/faster models — so DO NOT decide by hand whether labels, help text, or docs are present. Run the checker and let the tool tell you. This is a hard step of every write, not an optional nicety.

**Before every write — non-skippable:**
1. Call `validate_code(mode="both")` on the generated code. This runs the offline BP check (catches `BPErrorLabelIsText` — raw text where a label is required — missing labels/help text, and reference errors) in well under a second.
2. Read the result. If it reports ANY error or warning about a missing label, missing help text, a raw-text string, or a missing doc, **fix it and re-run `validate_code` until it is clean** — then write. Never write an object that still has open BP findings from `validate_code`.
3. Only then call `d365fo_file(action="create"/"modify")`.

**After writing a substantive object (table, EDT, class, form, security artifact) — run the real BP compiler:**
4. Run the full `xppbp` check on the written object — either `d365fo_file(..., runBestPractice=true)` in the write call, or `run_bp_check(objects[])` afterward. This is slower (needs the compiler, takes seconds) so it is not for trivial edits, but for any real deliverable it is required: it is the authoritative confirmation that ALL best practices pass, not just the offline subset.
5. If `xppbp` reports findings, fix them via `d365fo_file(action="modify")` and re-run until clean. Report the final BP status to the user in one line (e.g. "xppbp: clean" or the remaining monikers).

**Never** tell the user an object "respects best practices" from your own reading of it. That claim is only valid when it comes from a `validate_code` + `xppbp` result you actually ran. If you have not run the checker, say so instead of asserting compliance.

This section is about RUNNING the checks the server already ships, not about restating BP rules here — the rules live in the tools and in `get_knowledge`.

---

## Hard mechanics

**Target model & paths.** Model name and project path come from `.mcp.json` — never ask, never scan the filesystem, never infer the model from search results (that is the source model of the object, not the write target). Never switch projects autonomously; if a different model seems needed, ASK.

**D365FO objects go through MCP tools only.** NEVER use a built-in file-write tool (`create_file`, `edit_file`, `apply_patch`, `str_replace`, ...) on `.xml`/`.xpp` files — not even as a fallback. They bypass `IMetadataProvider` and corrupt the metadata model. If `d365fo_file` errors, STOP and report the error verbatim. Use `get_object_info`/`search`, not `read_file`, to read AOT objects (avoids scanning hundreds of model folders and flooding context).

**No bricolage fallback.** When an MCP tool fails, do not work around it with a shell script or an ad-hoc command — STOP and report the error verbatim.

**Writes apply immediately — no preview.** `d365fo_file(action="create"/"modify")` writes to disk the moment it is called. Therefore: (1) describe the exact change in chat — object, operation, before->after — and wait for explicit confirmation ("apply", "ok", "yes"); (2) call the tool ONCE — `isError=true` means it did NOT apply, fix and retry; success means done, do not re-ask; (3) revert with `d365fo_file(action="undo", filePath)` or pass `createBackup=true`; (4) propose a feature branch (`git switch -c mcp/<task>`) before multi-file tasks — propose, never create autonomously.

**Post-write diff must be additive or narrowly targeted.** After a write, verify via `get_workspace_info(changes=true)` that no unrelated nodes (`<DataSources>`, `<Controls>`, methods, pattern metadata) disappeared. If they did, the edit failed -> `undo` and retry with a targeted operation.

**Builds are user-triggered.** NEVER run `build_d365fo_project()` automatically — it blocks the user. Only on explicit request ("build", "compile", "check errors"), then fix errors via `d365fo_file(action="modify")` and rebuild until clean.

---

## Local conventions (not known to the server)

**XML doc comments — mandatory, English, by default.** Every class and method authored or substantially modified carries `/// <summary>`, `/// <param>` for each parameter, `/// <returns>` when it returns a value, and `/// <remarks>` when behavior is not self-evident (especially: name the standard object a CoC wrapper extends and why). Written in English regardless of the surrounding code. Comments state *why*, never *what*.

**Labels — this environment uses {{LABEL_LANGUAGES_INLINE}}.** Always pass `languages: [{{LABEL_LANGUAGES_JSON}}]` to `labels(action="create")`. Call `labels(action="search")` before creating — reuse an existing label rather than adding a duplicate. Never put a raw string in `info()` / `warning()` / `error()`; use a `@{{MODEL}}:LabelId` reference.

**Object naming — handled natively by the patched server (`EXTENSION_NAMING_STYLE=prefix-first`).** The server is patched to produce the team convention automatically; you do NOT hand-build names or override the token. Pass the BASE object name and let the server apply the style. Expected results on this machine (prefix `{{PREFIX}}`, model `{{MODEL}}`):
- CoC class extension -> `{Prefix}_{Base}_Extension` (e.g. `{{PREFIX_BARE}}_SalesFormLetter_Extension`) — prefix first, underscore-separated.
- AOT element extension (table, form, security, menu, menu item, enum, EDT, data entity) -> `{Base}.{ModelName}` with NO "Extension" word (e.g. `SalesLine.{{MODEL}}`) — the Visual Studio default.
- New non-extension object (EDT, form, class, menu item...) -> `{Prefix}_{Name}` (e.g. `{{PREFIX_BARE}}_MyNewEdt`).

Prefix and model come from the workspace config, never from a feature, ticket, or customer name. Do NOT re-inject the prefix into a name that already carries it (that is what produces a `{{PREFIX_BARE}}_InventTable{{PREFIX_BARE}}_Extension` doubling). If the produced name is ever wrong, verify `EXTENSION_NAMING_STYLE=prefix-first` and `EXTENSION_PREFIX` are set in `.mcp.json` — do not work around it by hand.

**Remediation cap.** When a generated object fails to build, cap remediation at **2-3 attempts**, then roll back rather than patching a defect forward. (Learned cost rule, not an X++ rule.)

---

## Working style

Peer-level and direct. State the recommendation and the reasoning — do not hedge with three equivalent options when one is correct. Give a verdict, not reassurance; never call something "acceptable" to be agreeable — evaluate it and say yes/no with the reason. Surface risk early: transaction scope, locking, performance on large sets, upgrade impact, security. When uncertain, verify against the index or ask — never invent. Match response depth to the task.

---

## The Copilot side

`.github/copilot-instructions.md` in this same workspace is read by GitHub Copilot in Visual Studio; this file is read by Claude Code. They coexist — each client ignores the file of the other, and the installer renders both from the same templates. Both point at the same patched MCP server, so the naming convention is identical in both. The only intended divergence is the terminal rule: Copilot inside Visual Studio hangs when a terminal command runs, the Claude Code CLI does not — the prohibition stands in both, the reason differs. The real rules live in the MCP server that both clients share.

---

## Error recovery

Tool returns nothing -> try alternative terms (Cust vs Customer), widen scope, check spelling; then tell the user the object may not exist. Read every write-tool response: `isError=true` means NOT applied.

**Trust the tools, not training data. Accuracy over assumptions.** Best-practice compliance is something you VERIFY by running `validate_code` and `xppbp`, never something you assert from reading the code. If the checker did not run, the object is not confirmed — run it.
