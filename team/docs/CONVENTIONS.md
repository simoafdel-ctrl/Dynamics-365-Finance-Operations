# Team conventions enforced by this install

What the assistant is instructed to do once the installer has run, and what you should expect
from it. This is the short version of the two generated instruction files — read it once.

Placeholders: prefix `ABC_`, model `ABC`. Your machine uses its own, and the generated
`CLAUDE.md` in your projects folder spells yours out explicitly.

---

## 1. Object naming — produced by the server, not by hand

`EXTENSION_NAMING_STYLE=prefix-first` is our convention. The patched server applies it
automatically: you pass the **base** object name and the server produces the final one.

| Object kind | Produced name | Example |
|---|---|---|
| CoC class extension | `{Prefix}_{Base}_Extension` | `ABC_SalesFormLetter_Extension` |
| AOT element extension (table, form, security, menu, menu item, enum, EDT, data entity) | `{Base}.{ModelName}` — **no** "Extension" word | `SalesLine.ABC` |
| New non-extension object (class, EDT, form, menu item…) | `{Prefix}_{Name}` | `ABC_MyNewEdt` |

**Two independent tokens, deliberately.** CoC classes and new objects take the **object
prefix**; dot-notation extensions take the **model name**, which is what Visual Studio
generates natively. They are usually equal. Where they are not — model `Abcco`, prefix `ABC_` —
you correctly get `ABC_SalesLine_Extension` *and* `SalesLine.Abcco`.

**Idempotent.** Re-normalising a correct name is a no-op, so no doubled
`ABC_SalesLineABC_Extension`, and a stale `SalesLine.ABCExtension` from the old style is
converted to the clean `SalesLine.ABC`. This is what stops parallel duplicate extension objects
from appearing.

**What this means for you:** ask for `SalesLine`, not for `ABC_SalesLine_Extension`. Do not
hand-build names and do not let an assistant "fix" one. If a produced name looks wrong, the
configuration is wrong — check it, do not work around it.

Prefix and model come from the machine configuration, **never** from a feature name, a ticket
number or a customer name.

## 2. Best practices are verified, never asserted

The single rule that changes the most in day-to-day quality: an assistant may not tell you code
is best-practice compliant from having read it. Compliance is a **tool result** or it does not
exist.

**Before every write:** `validate_code(mode="both")` — the offline BP and reference check, well
under a second. It catches `BPErrorLabelIsText` (raw text where a label is required), missing
labels, missing help text, missing docs, broken references. Any finding is fixed and re-checked
before anything is written.

**After writing a real object** (table, EDT, class, form, security artefact): the actual
`xppbp` compiler check, via `run_bp_check(objects[])` or `build_d365fo_project(bpCheck: true)`.
Slower, so not for trivial edits, but it is the authoritative verdict — the offline check is a
subset. Findings are fixed and the check re-run until clean, and the final status is reported in
one line.

**If an assistant claims compliance without a checker result, it is an unverified claim.** Ask
for the check. This rule exists because the failure mode is not laziness, it is confidence:
assistants describe what an object "should" contain rather than testing what it does.

## 3. AOT objects go through the MCP tools only

`.xml` and `.xpp` under `PackagesLocalDirectory` are written with `d365fo_file` and read with
`get_object_info` / `search`.

Never a text edit, **not even as a fallback** when a tool errors. Text edits bypass
`IMetadataProvider`, and whitespace and element ordering in AOT XML are load-bearing — you
corrupt the metadata model, and Visual Studio keeps a stale in-memory copy on top. When an MCP
tool fails, the correct behaviour is to stop and report the error verbatim, not to improvise a
script around it.

Reading with `get_object_info` rather than opening raw files is also a cost rule: raw AOT XML is
verbose, it stays in the conversation, and it pushes out the context you actually need.

## 4. Writes apply immediately

`d365fo_file(action="create"/"modify")` hits the disk the moment it is called. There is no
preview and no staging. So:

- the assistant describes the change first — object, operation, before/after — and waits for
  your explicit "ok";
- it calls the tool **once**: `isError=true` means nothing was applied, success means it is done
  and there is nothing to confirm again;
- `d365fo_file(action="undo", filePath)` reverts, and `createBackup=true` keeps a `.bak`;
- after the write, the diff must be additive or narrowly targeted — if unrelated nodes
  (`<DataSources>`, `<Controls>`, methods, pattern metadata) vanished, the edit failed and gets
  undone rather than patched.

On a multi-file task, a feature branch gets **proposed** — never created behind your back.

## 5. Builds are yours to trigger

`build_d365fo_project()` is never run on the assistant's own initiative, because it blocks your
VM for minutes. It runs when you ask ("build", "compile", "check errors"). The exception is a
BP-only check when you asked for a finished deliverable.

## 6. Grounded workflows — the `prepare` step is not optional

| Task | Chain |
|---|---|
| Extend an existing object | `prepare(mode="change")` → generate → `validate_code(mode="both")` → confirm → `d365fo_file(action="modify")` |
| New object | `prepare(mode="create")` → generate → `validate_code(mode="both")` → `d365fo_file(action="create")` |
| New form | `object_patterns(analyze)` → `object_patterns(spec)` → `generate_object(mode="scaffold", cloneFrom)` → `object_patterns(validate)` → `d365fo_file(action="create")` |

`prepare` returns the real method signature, the CoC wrappers that already exist, a collision
check and a grounding token bound to that object — the write tools reject a token issued for a
different one. It is what stops an assistant from inventing a signature or creating a second
class next to one that already owns the target.

Form XML is never hand-written. A form named by you as an example is a **pattern contract**:
its pattern family and required scaffolding must be preserved, and missing pattern elements
make the generation a failure even when the XML parses.

## 7. Reuse before creating

`prepare(mode="change")` lists the existing CoC wrappers and event handlers. If a class in the
custom model already owns the target, the new method goes there. A parallel, feature-named class
is created only when you explicitly ask for one.

## 8. Documentation — English XML doc comments, mandatory

Every class and method written or substantially modified carries `/// <summary>`, one
`/// <param>` per parameter, `/// <returns>` when it returns a value, and `/// <remarks>` when
the behaviour is not self-evident — in particular naming the standard object a CoC wrapper
extends, and why.

**In English, regardless of the surrounding code.** Comments say *why*, never *what*. A missing
doc is a `validate_code` finding to fix before writing, not a nicety.

## 9. Labels

Created in the languages configured for the environment (`index.labelLanguages`, echoed into
your generated instruction files, e.g. `en-US` and `fr-CA`) — always passed explicitly to
`labels(action="create")`.

`labels(action="search")` comes first: reuse an existing label instead of adding a duplicate.
And no raw strings in `info()` / `warning()` / `error()` — `@ABC:LabelId` references only. The
offline BP check flags raw text as `BPErrorLabelIsText`, which is why rule 2 catches this before
a write rather than at compile time.

## 10. X++ specifics that are easy to get wrong

- Never copy default parameter values into a CoC wrapper signature.
- Never `today()` — use `DateTimeUtil::getToday(DateTimeUtil::getUserPreferredTimeZone())`.
- The target model comes from `.mcp.json`. The model shown on a search result is the object's
  **source** model, not where your new file belongs.
- `update_symbol_index` is not called after a `d365fo_file` write — the index already refreshed.
  It is for files changed outside the server.

## 11. Remediation cap

When a generated object fails to build, remediation is capped at **2–3 attempts**, then rolled
back rather than patched forward. This is a cost rule learned the hard way, not an X++ rule: past
three attempts the assistant is usually defending a wrong design instead of fixing a defect.

---

## Where these rules live

They are not in this document — this is the summary. They are enforced from three places:

1. **The MCP server itself** — the `xpp_system_instructions` prompt and `get_knowledge` hold
   every rule *about X++*: select grammar, CoC authoring, SysOperation, number sequences, BP
   rules, security, AX2012 → D365FO migration. An assistant queries those instead of answering
   from training data.
2. **The generated instruction files** in your projects folder — `CLAUDE.md` for Claude Code,
   `.github\copilot-instructions.md` for Copilot. Rendered from
   [`team/templates/`](../templates/) with your prefix, model and label languages.
3. **The patched server code** — naming is mechanical, so it is not left to anyone's discipline.

**To change a team rule, edit the template in this repository and have everyone re-run the
installer.** Editing your local generated file changes your machine only, is overwritten on the
next install, and never reaches your colleagues. The header of every generated file says so.
