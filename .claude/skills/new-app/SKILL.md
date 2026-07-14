---
description: Scaffold and register a new Innigkeit app. Use when asked to create, add, or build a new app or userspace program.
argument-hint: <app-name>
---

# New app: $ARGUMENTS

## 1. Create the app directory

```
apps/$ARGUMENTS/
  main.zig
  manifest.toml
```

**`manifest.toml` template:**
```toml
name = "$ARGUMENTS"
version = "0.1.0"
description = ""

[entitlements]
# Booleans. Omit a key to take the default (false, except spawn = true).
# Available: keyboard, storage, network, mouse, framebuffer, gpu, secure_vault,
#            spawn, trusted_spawner_only, internal_service
spawn = true
```

Only request entitlements the app actually needs. `spawn = true` is the only default.

**`main.zig` minimal template:**
```zig
const std = @import("std");
const sys = @import("innigkeit");

pub fn main() void {
    // entry point; process allocator available via sys.allocator
}
```

## 2. Register in apps/root.zig

!`grep -n 'comptime\|pub const\|addApp\|include' apps/root.zig | head -20`

Add the new app following the existing pattern.

## 3. Build and sign

```sh
zig build
```

The codesign step runs automatically. Check that `apps/$ARGUMENTS/$ARGUMENTS.codesig` was produced.

## 4. Verify

```sh
zig build verify
```

The new app should appear in the initfs and the build should stay green.
