/**
 * `labels` write-plumbing parameter specs — fetched on demand instead of being
 * inlined in the wire schema.
 *
 * Same trade as issue #825 made for d365fo_file and generate_object: `labels`
 * was the single largest tool in the ListTools payload (6,197 of 53,450 chars,
 * against a 6,200 per-tool cap), and most of that was create/rename plumbing —
 * packageName, packagePath, projectPath, solutionPath, addToProject,
 * createLabelFileIfMissing, sortLabels, languages, searchPaths, updateIndex,
 * allowExtensionLabelFile, defaultComment, description. Every one of them is
 * auto-resolved in the normal path, so the overwhelmingly common call never
 * names any of them — yet all thirteen were re-sent on every single request.
 *
 * They remain fully accepted: the handler merges `{...args, ...args.params}`,
 * so both the flat and the nested spelling work. Reachable as
 * get_knowledge(kind="op-spec", topic="labels").
 *
 * tests/tools/labelsOpSpecs.test.ts guards that the schema and this file do not
 * drift apart — a parameter must be in exactly one of them.
 */

/** Parameter name → its contract. Everything here is accepted but unpublished:
 *  the thirteen above left the wire schema, and createIfMissing was added here
 *  rather than to it (the payload had 124 chars of headroom). */
export const LABELS_OVERRIDE_PARAMS: Record<string, string> = {
  packageName:
    '[create|rename] Package name for the model. Auto-resolved if omitted.',
  packagePath:
    '[create|rename] Root packages path. Auto-detected from environment config if omitted.',
  projectPath:
    '[create] Path to the .rnrproj project file. Auto-detected from .mcp.json if omitted.',
  solutionPath:
    '[create] Path to the .sln solution directory. Fallback to find .rnrproj if projectPath is not set.',
  addToProject:
    '[create] Add label file XML descriptors to the VS project (default: true).',
  createIfMissing:
    '[create] Upsert-lite: create the label when absent, and when it already exists reuse it ' +
    '(existing text untouched) and report "@labelFileId:labelId" as a success instead of an ' +
    '"already exists" warning. Default false — PASS IT. A search before a create is never ' +
    'necessary with it: this one call IS the search-then-create pair. Combine with labels[] to ' +
    'do a whole object\'s labels in one call. It never overwrites — use action="update" for that.',
  createLabelFileIfMissing:
    '[create] Create the AxLabelFile when the model does not have it (default: FALSE). A label file ' +
    'is a deliverable of its own, so it is never created as a side effect: the call fails instead ' +
    'and names the label files the model does have. Use one of those, or ask which one to use when ' +
    'the request does not say. Set true only once a new file is confirmed to be wanted.',
  sortLabels:
    '[create] Sort labels alphabetically in .label.txt (default true, from LABEL_SORT_ORDER env; ' +
    'false = append at end).',
  languages:
    '[create] string[] — write a locale you have NO translation for (falls back to the en-US text). ' +
    'By default the label goes to exactly the languages in `translations` and nowhere else. ' +
    'LABEL_LANGUAGE_SCOPE=model restores the old "every locale present in the model" behaviour.',
  defaultComment:
    '[create] Developer comment for languages without an explicit comment.',
  description:
    '[create] Label description (comment line in .label.txt). Defaults to the VS project name from ' +
    '.rnrproj when omitted, then falls back to labelFileId. Per-translation comment and ' +
    'defaultComment take priority.',
  searchPaths:
    '[rename] string[] — additional absolute directory paths to scan for X++ / XML references.',
  updateIndex:
    '[create|rename] Update the MCP label index after writing (default: true).',
  allowExtensionLabelFile:
    '[create|rename] Allow writing to a label file EXTENSION ("_Extension" marker). Default false — ' +
    "new labels belong in the model's ORIGINAL label file.",
};

/** The contract rendered for get_knowledge(kind="op-spec", topic="labels"). */
export function renderLabelsOpSpec(): string {
  return [
    'labels — write plumbing (action=create / action=rename)',
    '',
    'FIRST, the shape that removes the round trips (measured over 1,515 real MCP',
    'calls: 268 `labels` calls against 171 writes, and `labels`→`labels` the most',
    'frequent consecutive pair in the corpus, 177 times — nearly all of it',
    'search-then-info-then-create, once per label):',
    '  • createIfMissing=true — do NOT search first. It creates when absent and',
    '    reuses when present, so the create IS the search.',
    '  • labels=[{labelId, translations}, …] — every label of an object in ONE',
    '    call, shared labelFileId/model at the top level.',
    '  • query=["…","…","…"] on search — several phrasings in ONE call.',
    '  • best of all, no `labels` call at all: d365fo_file create/modify resolve a',
    '    raw-text label / fieldLabel to an existing or new @Ref by themselves and',
    '    report which one they used (autoCorrect=false opts out).',
    '',
    'These are accepted flat or nested in `params`; all are optional and',
    'auto-resolved when omitted, which is why they are not in the wire schema.',
    'The published schema already carries everything a normal call needs:',
    'action, labelId, labelFileId, model, translations[], labels[], query,',
    'language, maxResults, verbose, oldLabelId, newLabelId, dryRun.',
    '',
    ...Object.entries(LABELS_OVERRIDE_PARAMS).map(([k, v]) => `  ${k}: ${v}`),
  ].join('\n');
}
