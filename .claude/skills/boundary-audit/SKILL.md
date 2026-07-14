---
description: Run the user→kernel boundary threat-model checklist against a syscall handler or copy path. Use when asked to audit, review for security, or check a boundary.
argument-hint: <file-or-syscall-name>
disable-model-invocation: true
---

# Boundary audit: $ARGUMENTS

!`rg -n 'copyFromUser|copyToUser|readUser|writeUser|userSlice|UserAccess|validateUserBuffer|safe\.memcpy|safe\.atomicLoad' $ARGUMENTS 2>/dev/null || echo "(run with a specific file path)"`

Work through each question for the target. Answer each one explicitly.

## Threat-model checklist (docs/design-goals.md)

**Bad pointer**
- Is the user pointer validated before use (`validateUserBuffer` or `copyFromUser`)?
- If the pointer is in-range but unmapped, does the path return `error.BadAddress` (not panic)?
- Are all accesses going through `copyFromUser`/`copyToUser`/`readUser`/`writeUser` (fault-safe on x64)?
- Are there any direct user-pointer dereferences outside these helpers?

**Concurrent mutation (TOCTOU)**
- Is there a validate-then-use gap a sibling thread could exploit with `vmem_unmap`?
- Is any user memory touched while holding a spinlock (interrupts disabled)?

**Integer overflow**
- Are `ptr + len`, `offset + size`, `count * stride` checked for wrap?
- Does `validateUserBuffer` cover the full range (it checks `ptr +% len < ptr`)?

**Alignment / bounds**
- Does the handler assume alignment the user controls?
- Are fixed-size structs copied via `readUser`/`writeUser` (which go through `safe.memcpy`)?

**Resource exhaustion**
- Can the user force unbounded kernel allocation or work (e.g. unbounded loop on user-supplied count)?

**Capability confusion**
- Is the right object type, rights set, and generation checked before use?
- Is `getAndRefLocked` used (validates generation + takes ref before unlock)?

**Blocking discipline**
- Does any path block while holding a lock?
- Does any path hold a `UserAccess` window across a blocking call?

## Output

For each question: PASS / FAIL / N/A with a brief note. Flag any FAIL with severity (HIGH = user-triggerable kernel panic or privilege escalation, MEDIUM = requires specific conditions, LOW = defense-in-depth).
