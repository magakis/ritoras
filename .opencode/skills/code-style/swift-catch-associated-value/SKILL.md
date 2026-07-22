---
name: "Swift Catch Pattern for Enum Cases with Associated Values"
description: "Apply when a Swift do-catch block catches an enum case that has an associated value (e.g. case jobFailed(String)) and the catch body needs to rethrow — 'catch EnumCase { throw }' fails with 'expected expression in throw statement' because the associated value is not bound. If the enum case has no associated value, skip."
confidence: 0.8
domain: "code-style"
source: "session-extraction"
created: "2026-07-21"
last_confirmed: "2026-07-21"
metadata:
  opencode:
    tags: [swift, error-handling, catch, enum, associated-value, compile-error]
    related_skills: [swift-nonisolated-var, swift-raw-pointer-subscript]
---

# Swift Catch Pattern for Enum Cases with Associated Values

## When to Apply

Apply when a Swift `do-catch` block catches an enum case that has an associated value (e.g., `case jobFailed(String)`) and the catch body needs to rethrow or access the value. The pattern `catch EnumCase { throw }` fails to compile with "expected expression in 'throw' statement."

## Overview

Swift's `catch` clause can pattern-match specific enum cases. When the case has no associated value (`case timeout`), `catch MyError.timeout { ... }` works fine. But when the case has an associated value (`case jobFailed(String)`), the bare pattern `catch MyError.jobFailed` does not bind the value — and any `throw` inside that catch block has no expression to throw.

The compiler error is:

```
error: expected expression in 'throw' statement
```

This is confusing because it points at the `throw` keyword, not at the catch pattern. The actual problem is that `catch MyError.jobFailed` doesn't bind the associated `String`, so there's nothing to rethrow.

## Action

### 1. Identify the error

Look for `expected expression in 'throw' statement` in Xcode build output or CI logs. The line number points to the `throw` inside a catch block, not to the catch pattern itself.

### 2. Bind the associated value in the catch pattern

Change:

```swift
} catch WhisperError.jobFailed {
    throw // ❌ expected expression in 'throw' statement
}
```

To:

```swift
} catch WhisperError.jobFailed(let message) {
    throw WhisperError.jobFailed(message) // ✅ binds and rethrows
}
```

### 3. For rethrowing the same error, bind and reconstruct

If the goal is to rethrow the caught error (common when the error is terminal and should propagate):

```swift
} catch WhisperError.jobFailed(let message) {
    throw WhisperError.jobFailed(message)
}
```

### 4. For using the value without rethrowing

```swift
} catch WhisperError.jobFailed(let message) {
    logger.error("Job failed: \(message)")
    // handle, don't rethrow
}
```

### 5. Check exhaustiveness after adding catch arms

If you add a new enum case with an associated value, existing `switch` statements on that enum may become non-exhaustive. Search for all `switch` blocks that match the enum and add the new case.

## Examples

```swift
enum WhisperError: Error {
    case timeout           // no associated value — catch works bare
    case jobFailed(String) // associated value — MUST bind in catch
    case networkError(Error)
}

do {
    try await transcribe()
} catch WhisperError.timeout {
    // ✅ fine — no associated value to bind
} catch WhisperError.jobFailed(let reason) {
    // ✅ correct — binds the String
    throw WhisperError.jobFailed(reason)
} catch WhisperError.jobFailed {
    // ❌ compile error — String is not bound
    throw // ❌ "expected expression in 'throw' statement"
}
```

## Common Pitfalls

- **Error message misleads**: the compiler says "expected expression in throw" but the real issue is the unbound associated value in the catch pattern. Don't try to fix the `throw` — fix the `catch`.
- **Bare catch looks correct for cases without associated values**: `case timeout` works with `catch WhisperError.timeout { ... }`. This creates a false expectation that `catch WhisperError.jobFailed { ... }` should also work. It doesn't — the associated value changes the pattern-matching requirement.

## Evidence

- Session 2026-07-21: CI build failed (29-second compile error) with `shared/WhisperClient.swift:525:22: error: expected expression in 'throw' statement`. The code was `} catch WhisperError.jobFailed { throw // re-throw terminal failure }`. Fixed by changing to `catch WhisperError.jobFailed(let message) { throw WhisperError.jobFailed(message) }`. Commit `0729e6c`.
- Searched the entire repo for bare-`throw` patterns — this was the only instance.

## Verification Checklist

- [ ] No `catch EnumCase {` patterns exist where `EnumCase` has an associated value without a `let` binding
- [ ] `grep -rn "catch.*{.*throw" *.swift` returns only patterns with bound associated values
- [ ] CI build passes with no "expected expression in throw statement" errors
