//! Import resolution, as an injected interface.
//!
//! §4.14 says import names are **logical**: "The build program supplies the
//! resolver (search roots and an explicit name→file map), so the same
//! `$import "net"` resolves to different files on different targets." Even at
//! stage 0 that means resolution does not belong to the evaluator — so the
//! evaluator takes one of these and never touches a filesystem itself, which
//! also lets the interpreter's own tests import from an in-memory map.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Loader = struct {
    ctx: *const anyopaque,
    resolveFn: *const fn (ctx: *const anyopaque, arena: Allocator, name: []const u8) LoadError!Resolved,

    pub const Resolved = struct {
        /// Identity for the load-once cache: two `$import`s with the same key
        /// are the same module and must yield the same block.
        key: []const u8,
        source: []const u8,
    };

    pub const LoadError = error{ NotFound, ReadFailed, OutOfMemory };

    pub fn resolve(self: Loader, arena: Allocator, name: []const u8) LoadError!Resolved {
        return self.resolveFn(self.ctx, arena, name);
    }
};
