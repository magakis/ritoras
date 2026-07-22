---
name: "Trace Data Flow After Reviewer Fixes"
description: "Apply when applying a reviewer-recommended code change that alters what VALUE a variable holds (e.g. switching from array index to identifier lookup, from id to name, from camelCase to snake_case) — the reviewer evaluated code structure, not runtime data flow. The fix compiles cleanly but can break runtime behavior (empty grids, missing items, wrong lookups). Identify every consumer and verify the new value still satisfies each filter/lookup/comparison. If the reviewer fix doesn't change a variable's value source, skip."
confidence: 0.8
domain: "workflow"
source: "session-extraction"
version: 1.0.0
created: "2026-07-19"
last_confirmed: "2026-07-21"
metadata:
  opencode:
    tags: [reviewer, data-flow, runtime-bug, verification]
    related_skills: []
---

# Trace Data Flow After Reviewer Fixes

## When to Apply

Apply when applying a reviewer-recommended code change that alters what VALUE a variable holds. The reviewer evaluated code quality (clarity, fragility, idioms) but typically did NOT trace runtime data flow downstream — the fix may compile cleanly yet produce empty grids, missing items, or wrong lookups.

## Overview

Reviewers flag code smells: "this index-based lookup is fragile, use an identifier instead." The recommendation is often correct at the code-quality level but naively applied. The reviewer didn't audit every consumer of the variable, so the new value source may not match what downstream code expects.

Common variants where this trap fires:

- Index-based lookup → identifier-based lookup (the identifier may be the wrong field)
- `id` → `name` swap (downstream filters by the other)
- camelCase → snake_case (downstream regex or string compare breaks)
- Optional → force-unwrap (downstream nil-handling now crashes)
- Type narrowing (`Any` → concrete type) (downstream casts now fail)

These bugs are NOT caught by the compiler. They manifest at runtime as empty UI, missing data, wrong selections, or crashes on specific code paths. The build-fixer / type-checker passes; the user hits the bug on device.

## Action

1. **Before applying the reviewer's fix**, identify the variable being changed. Ask: "What value did this variable hold BEFORE the fix, and what value does it hold AFTER?"

2. **Find every consumer of the variable.** Use grep (or sandboxed search) to find all references — across the WHOLE codebase, not just the file the reviewer cited:
   ```bash
   grep -rn "variableName" --include="*.swift" .
   ```
   Downstream consumers often live in sibling files.

3. **For each consumer, verify the new value still satisfies its logic:**
   - If the consumer filters / looks up by the variable: confirm the new value matches the data being filtered. (E.g., if `selectedCategory` now holds `"people"` but `reloadData()` filters by `category.name == "People & Body"`, the lookup returns nil → empty grid.)
   - If the consumer compares to a literal: confirm the literal matches the new format.
   - If the consumer persists the value (UserDefaults, file): confirm the read path expects the new format.

4. **If any consumer would break**, choose one:
   - **(Preferred) Align the new value to what consumers expect** — change the value source so existing downstream code keeps working unchanged. This minimizes diff and risk.
   - **(Alternative) Update each consumer** to match the new value source. More invasive; only when the new value source is genuinely better.

5. **After applying the fix, dispatch the build-fixer** with an explicit data-flow verification check: "Confirm variable X's value at the source matches what consumers Y and Z filter by."

## Common Pitfalls

- **Trusting the reviewer's "the fix is correct"**: reviewers evaluate code structure, not runtime data flow. Their recommendation can be structurally sound and runtime-broken.
- **Build-fixer passes ≠ runtime correct**: type-checks and compile don't catch value-source mismatches. The bug surfaces only when the code path executes (e.g., when the user taps a category and the grid goes empty).
- **Restricting the consumer search to one file**: downstream consumers often live elsewhere. Always grep the whole codebase.
- **"It worked for the index, so the identifier will work too"**: index and identifier carry DIFFERENT VALUES. The lookup-mechanism change is incidental; the value-source change is what matters.

## Examples

```swift
// Reviewer said: "index-based lookup is fragile, use accessibilityIdentifier"

// BEFORE (works because index matches in both arrays):
guard let index = categoryIconButtons.firstIndex(of: sender) else { return }
selectedCategory = EmojiData.categories[index].name  // holds "People & Body"

// AFTER (reviewer's naive fix — breaks reloadData):
guard let categoryId = sender.accessibilityIdentifier else { return }
selectedCategory = categoryId  // holds "people" — but reloadData filters by name!

// reloadData():
let cat = EmojiData.categories.first { $0.name == selectedCategory }
// selectedCategory = "people", no category.name == "people" → nil → empty grid

// ✅ CORRECT FIX: align identifier to what consumers expect
// In setup:
button.accessibilityIdentifier = cat.name  // was catId, now matches reloadData's filter
// In tap handler:
selectedCategory = sender.accessibilityIdentifier  // now "People & Body" ✓
```

## Evidence

- Session 2026-07-19 (Ritoras emoji-panel redesign): reviewer flagged `EmojiPanelView.categoryIconTapped` and `updateTabSelection` as fragile for using array-index lookup between `categoryIconButtons` and `EmojiData.categories`. Recommended switching to `accessibilityIdentifier`. The coder applied the fix; the build passed static inspection. The build-fixer then caught that `accessibilityIdentifier` was set to `catId` (e.g., `"people"`) while `reloadData()` filters by `category.name` (e.g., `"People & Body"`). Tapping any category would have shown an empty grid. Root cause: reviewer evaluated the lookup mechanism (structural), not the value source (runtime). Fix: align the identifier to `category.name`.

## Verification Checklist

- [ ] Identified the variable being changed by the reviewer's fix
- [ ] Grepped the whole codebase for consumers (not just the file the reviewer cited)
- [ ] Each consumer's filter/lookup/comparison verified against the new value format
- [ ] If consumers break, either aligned the value source OR updated each consumer
- [ ] Build-fixer dispatched with explicit data-flow verification (not just compile check)
