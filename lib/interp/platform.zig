//! The platform layer, as an injected interface.
//!
//! §4.16 is emphatic that `$extern` is "the **only** door to the platform" and
//! that I/O is library code in a per-target root block. Stage 0 has no
//! `$extern` (BOOTSTRAP.md §1.2), so it substitutes opaque builtins — but the
//! substitution keeps the same shape: the evaluator holds an interface and the
//! driver supplies the implementation. Nothing under lib/interp/ opens a file
//! or reads the process environment itself.
//!
//! That also keeps these builtins testable: the evaluator's own tests inject a
//! fake platform backed by an in-memory map.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Platform = struct {
    ctx: *const anyopaque,
    readFileFn: *const fn (ctx: *const anyopaque, arena: Allocator, path: []const u8) PlatformError![]const u8,
    writeFileFn: *const fn (ctx: *const anyopaque, path: []const u8, bytes: []const u8) PlatformError!void,
    argsFn: *const fn (ctx: *const anyopaque, arena: Allocator) PlatformError![]const []const u8,

    /// `Failed` covers every reason the host gave up. The intrinsics turn it
    /// into a morphl value (`none`/`err`), never a compiler error: §8 requires
    /// failing operations to return `option`/`result` rather than panic.
    pub const PlatformError = error{ Failed, OutOfMemory };

    pub fn readFile(self: Platform, arena: Allocator, path: []const u8) PlatformError![]const u8 {
        return self.readFileFn(self.ctx, arena, path);
    }

    pub fn writeFile(self: Platform, path: []const u8, bytes: []const u8) PlatformError!void {
        return self.writeFileFn(self.ctx, path, bytes);
    }

    pub fn args(self: Platform, arena: Allocator) PlatformError![]const []const u8 {
        return self.argsFn(self.ctx, arena);
    }
};
