/**
 * The prefix a validator SUGGESTS must be the prefix the writer APPLIES.
 *
 * checkObjectNaming suggested `${prefix}${name}` — the resolved prefix, whose
 * trailing underscore has been stripped by design ("CON_" → "CON"). The write
 * path prepends resolveRegularObjectPrefixToken(), which keeps it. So on every
 * underscore-style model the two disagreed on the same screen:
 *
 *   Final name  : CON_QualityTier   ← what prepare() predicted, and what got written
 *   → Prefixed name: CONQualityTier ← what the suggestion told the caller to use
 *
 * An agent that follows the suggestion writes the name the validator invented;
 * one that follows the prediction writes the other. Both paths are grounded, and
 * they produced two different objects.
 */

import { describe, it, expect, afterEach, vi } from 'vitest';
import { checkObjectNaming } from '../../src/utils/objectNamingRules';
import { applyObjectPrefix } from '../../src/utils/modelClassifier';

const originalPrefix = process.env.EXTENSION_PREFIX;
const originalSource = process.env.EXTENSION_PREFIX_SOURCE;

afterEach(() => {
  if (originalPrefix === undefined) delete process.env.EXTENSION_PREFIX;
  else process.env.EXTENSION_PREFIX = originalPrefix;
  if (originalSource === undefined) delete process.env.EXTENSION_PREFIX_SOURCE;
  else process.env.EXTENSION_PREFIX_SOURCE = originalSource;
});

/** An empty symbol index: no conflicts, no inferred prefix to learn from. */
const emptyDb = () => {
  const stmt = { all: vi.fn(() => []), get: vi.fn(() => undefined), run: vi.fn() };
  return { prepare: vi.fn(() => stmt) } as any;
};

describe('the "Prefixed name" suggestion agrees with the write path', () => {
  it('keeps the underscore of an underscore-style prefix', async () => {
    process.env.EXTENSION_PREFIX = 'CON_';
    process.env.EXTENSION_PREFIX_SOURCE = 'config';

    const check = await checkObjectNaming(emptyDb(), {
      proposedName: 'QualityTier',
      objectType: 'table',
      modelName: 'ContosoRobotics',
    });

    const suggestion = check.suggestions.find(s => s.startsWith('Prefixed name:'));
    expect(suggestion).toBe('Prefixed name: CON_QualityTier');
    // …and that is exactly what a write would produce.
    expect(applyObjectPrefix('QualityTier', 'CON', 'ContosoRobotics')).toBe('CON_QualityTier');
  });

  it('leaves a PascalCase prefix concatenated, as the writer does', async () => {
    process.env.EXTENSION_PREFIX = 'Contoso';
    process.env.EXTENSION_PREFIX_SOURCE = 'config';

    const check = await checkObjectNaming(emptyDb(), {
      proposedName: 'QualityTier',
      objectType: 'table',
      modelName: 'ContosoRobotics',
    });

    const suggestion = check.suggestions.find(s => s.startsWith('Prefixed name:'));
    expect(suggestion).toBe('Prefixed name: ContosoQualityTier');
    expect(applyObjectPrefix('QualityTier', 'Contoso', 'ContosoRobotics')).toBe('ContosoQualityTier');
  });
});
