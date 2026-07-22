---
name: "UIButton Selection Highlight via Background Color"
description: "Apply when highlighting a UIButton as a selection indicator (active tab, picked category, segmented control) — adding a UIView subview and calling sendSubviewToBack does NOT reliably render behind UIButton's managed imageView; the icon disappears on launch. Use button.backgroundColor + layer.cornerRadius + masksToBounds=true instead. If not highlighting a UIButton, skip."
confidence: 0.9
domain: "tools"
source: "session-extraction"
version: 1.0.0
created: "2026-07-19"
last_confirmed: "2026-07-19"
metadata:
  opencode:
    tags: [uikit, uibutton, selection, highlight, ios]
    related_skills: []
---

# UIButton Selection Highlight via Background Color

## When to Apply

Apply when highlighting a UIButton as a selection indicator (active tab, picked category, segmented control) and the icon is invisible on launch because the highlight covers it. Use `backgroundColor` + `cornerRadius` instead of adding a subview.

## Overview

UIButton manages its own `imageView` subview. When you call `button.addSubview(highlightView)` then `button.sendSubviewToBack(highlightView)` (or `insertSubview(highlightView, at: 0)`), the highlight may still end up in front of the imageView at render time. UIButton's layout machinery re-adds/repositions its managed subviews as needed — your explicit z-order is not preserved across layout passes or image changes.

The reliable approach: set the button's `backgroundColor`, shape it into a circle via `layer.cornerRadius`, and clip with `masksToBounds`. The button's `imageView` natively renders on top of its background color — no z-order race possible.

## Action

1. Define an adaptive highlight color (or use any UIColor):
   ```swift
   static let categoryHighlightColor: UIColor = UIColor { tc in
       tc.userInterfaceStyle == .dark
           ? UIColor(white: 0.25, alpha: 1.0)
           : UIColor(white: 0.82, alpha: 1.0)
   }
   ```

2. On the selected button, apply the highlight via backgroundColor:
   ```swift
   button.backgroundColor = Self.categoryHighlightColor
   button.layer.cornerRadius = 22  // half of the known button height (44pt toolbar)
   button.layer.masksToBounds = true
   ```

3. On all deselected sibling buttons, clear:
   ```swift
   button.backgroundColor = .clear
   // cornerRadius and masksToBounds can stay set; invisible on a clear bg
   ```

4. Derive `cornerRadius` from the **known container height constraint**, not `button.bounds.height / 2`. At setup time, bounds is `.zero`. If the toolbar's `heightAnchor` is constrained to 44, hardcode `cornerRadius = 22`.

5. To increase contrast against the panel background, prefer introducing a dedicated `categoryHighlightColor` constant rather than reusing the search-pill background color — they're different visual contexts with different contrast requirements.

## Common Pitfalls

- **Adding a subview to UIButton for a background**: seems intuitive, fails in practice. UIButton's `imageView` is a managed subview whose z-order is not stable across layout passes. Even if `insertSubview(_, at: 0)` works in one code path, it can break after image changes or mode switches.
- **`button.bounds.height / 2` in setup**: bounds is `.zero` at config time. Hardcode the cornerRadius from the container's known height constraint.
- **`masksToBounds = false`**: the backgroundColor fills the entire button frame, ignoring cornerRadius. The "circle" becomes a rectangle.
- **Reusing the search-pill background color for the highlight**: they appear in different contexts (against different surrounding colors) and need different contrast levels. Use a dedicated constant.

## Examples

```swift
// ❌ WRONG: subview approach — imageView ends up behind the highlight
let highlight = UIView()
highlight.backgroundColor = Self.categoryHighlightColor
highlight.layer.cornerRadius = 22
button.addSubview(highlight)
button.sendSubviewToBack(highlight)  // unreliable — race with managed imageView

// ❌ ALSO WRONG: insert at index 0 — same race
button.insertSubview(highlight, at: 0)

// ✅ RIGHT: backgroundColor approach
button.backgroundColor = Self.categoryHighlightColor
button.layer.cornerRadius = 22
button.layer.masksToBounds = true
```

## Evidence

- Session 2026-07-19 (Ritoras emoji-panel redesign): `updateTabSelection()` first used `button.addSubview(highlight)` + `button.insertSubview(highlight, at: 0)`. The clock icon (default selection on keyboard launch) was invisible — the highlight covered it. A second attempt with `sendSubviewToBack(highlight)` had the same result. Replacing with `backgroundColor` + `cornerRadius` + `masksToBounds` fixed it immediately. Two failed subview attempts in one session, both with the same root cause.

## Verification Checklist

- [ ] The selected button's `backgroundColor` IS the highlight color (no subview added)
- [ ] `layer.cornerRadius` is hardcoded to half the known container height (not `bounds.height / 2`)
- [ ] `layer.masksToBounds = true` (or `clipsToBounds = true`)
- [ ] Deselected sibling buttons have `backgroundColor = .clear`
- [ ] The SF Symbol / title renders VISIBLE on top of the highlight on launch (the most common bug)
- [ ] The highlight color is a dedicated constant (not reused from a different visual context)
