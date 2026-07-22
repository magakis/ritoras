---
name: "UIScrollView + UIStackView Width Fill Trap"
description: "Apply when embedding a horizontal UIStackView inside a UIScrollView (contentLayoutGuide pattern) expecting the stackView to fill the visible width — it does NOT. The stackView takes its natural compressed width and arranged views cluster cramped on the left. Either constrain stackView.widthAnchor >= scrollView.frameLayoutGuide.widthAnchor, or skip the scrollView if all icons fit. If not embedding a stackView in a scrollView, skip."
confidence: 0.8
domain: "tools"
source: "session-extraction"
version: 1.0.0
created: "2026-07-19"
last_confirmed: "2026-07-19"
metadata:
  opencode:
    tags: [uikit, uiscrollview, uistackview, autolayout, ios]
    related_skills: []
---

# UIScrollView + UIStackView Width Fill Trap

## When to Apply

Apply when embedding a horizontal `UIStackView` inside a `UIScrollView` via the standard `contentLayoutGuide` pattern expecting the stackView to fill the scrollView's visible width. It does not — without an explicit width constraint, the stackView hugs its natural compressed width.

## Overview

The canonical "scrollable stack" pattern in UIKit:

```swift
scrollView.addSubview(stackView)
stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor).isActive = true
stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor).isActive = true
stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor).isActive = true
stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor).isActive = true
```

This anchors the stackView to the scrollView's **content** area (which can be larger than the visible frame). The stackView's width is determined by its `arrangedSubviews`' natural sizes — for buttons containing SF Symbols, that's the compressed icon width plus padding. The stackView does **not** expand to match the scrollView's visible frame.

Result: a horizontal row of icons that should be evenly distributed across the screen instead clusters cramped against the left edge. The rightmost arranged view is jammed against its left peer instead of pinned to the trailing edge.

## Action

Choose one of three fixes based on intent:

### Fix 1 — Don't use a scrollView (preferred when icons fit)

If your arranged views fit on screen at their natural sizes (count the icons, estimate width), use a plain `UIStackView` with `distribution = .fillEqually`. Each arranged view gets an equal share of the stackView's width (which itself fills its container via Auto Layout).

```swift
let stack = UIStackView(arrangedSubviews: buttons)
stack.axis = .horizontal
stack.distribution = .fillEqually
stack.alignment = .center
container.addSubview(stack)
// pin stack.leading/trailing/top/bottom to container — fills width naturally
```

This is what iOS does for its emoji keyboard category bar — the icons fit, no scrolling needed.

### Fix 2 — Pin stackView width to frameLayoutGuide (when scrolling is genuinely needed)

If you actually need scrolling (more icons than fit), constrain the stackView's width to be AT LEAST the scrollView's visible frame so it fills when content is small and scrolls when content is large:

```swift
stackView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor).isActive = true
```

Combined with `distribution = .fillEqually`, the stackView expands to fill the visible area when content fits and scrolls when it doesn't.

### Fix 3 — Natural compression + horizontal scroll (heterogeneous widths)

If you want each icon at its natural size with consistent spacing (icons have different widths, e.g. text labels mixed with images), use `distribution = .fill` and explicit spacing. The stackView's width is the sum of arranged views + spacing. If that exceeds the scrollView's frame, you get scrolling; if not, the icons cluster on the left by design.

## Common Pitfalls

- **Assuming contentLayoutGuide pinning auto-fills width**: it does not. `contentLayoutGuide` defines the scrollable content area, not the visible frame. The stackView hugs its natural compressed size unless explicitly widened.
- **Using `distribution = .fillEqually` inside a scrollView without a width constraint**: `fillEqually` divides the stackView's width equally among arranged views. If the stackView's width is the natural compressed size, each view gets a tiny sliver — icons may overlap or clip.
- **Reaching for a scrollView prematurely**: iOS emoji keyboards, tab bars, and category bars typically don't need scrolling — the icons fit. Adding a scrollView "for safety" causes the cramped-icons bug. Use a plain stackView first; add a scrollView only when the count overflows.
- **Testing only on wide devices**: cramped-icons may appear only on narrower screens (e.g. iPhone SE). Always test on the smallest target device.

## Examples

```swift
// ❌ WRONG: stackView hugs natural width, icons cluster cramped
scrollView.addSubview(stackView)
stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor).isActive = true
stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor).isActive = true
stackView.distribution = .fillEqually  // no effect — stackView is natural-width

// ✅ RIGHT (Fix 1): skip scrollView entirely
let stack = UIStackView(arrangedSubviews: buttons)
stack.distribution = .fillEqually
container.addSubview(stack)
// pin stack to container edges

// ✅ RIGHT (Fix 2): keep scrollView, pin width to visible frame
scrollView.addSubview(stackView)
// ... contentLayoutGuide pins ...
stackView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor).isActive = true
stackView.distribution = .fillEqually
```

## Evidence

- Session 2026-07-19 (Ritoras emoji-panel redesign): the category toolbar was refactored to `scrollView + fillEqually stackView` containing 11 buttons (ABC, clock, 8 category icons, backspace). On device, all icons clustered cramped on the left with no spacing; the backspace button was jammed against the clock button. Root cause: the inner stackView hugged its natural compressed width inside the scrollView's contentLayoutGuide. User feedback: "it feels like they're all cramped now on the left side... like no space in between them, all on top of each other." Reverted to a plain `UIStackView` with `fillEqually` — icons distributed evenly across the panel width.

## Verification Checklist

- [ ] If using a scrollView, the stackView has `widthAnchor >= scrollView.frameLayoutGuide.widthAnchor` OR is intentionally natural-width
- [ ] `distribution = .fillEqually` produces evenly-spaced icons on screen (if icons cluster, the stackView width is wrong)
- [ ] The rightmost arranged view is flush with the trailing edge of the visible area, not clustered with peers on the left
- [ ] No `distribution` set on a stackView whose width is natural-compressed — the combination is meaningless
- [ ] Tested on the smallest target device (cramped-icons may appear only on narrow screens)
