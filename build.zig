const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Stage 0 front end. Dependencies run one way:
    //   diag ← keyword ← lexer ← ast ← parser ← main
    const diag = b.addModule("diag", .{
        .root_source_file = b.path("lib/diag/diag.zig"),
        .target = target,
        .optimize = optimize,
    });

    const keyword = b.addModule("keyword", .{
        .root_source_file = b.path("lib/syntax/keyword.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lexer = b.addModule("lexer", .{
        .root_source_file = b.path("lib/lexer/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    lexer.addImport("diag", diag);
    lexer.addImport("keyword", keyword);

    const ast = b.addModule("ast", .{
        .root_source_file = b.path("lib/ast/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast.addImport("diag", diag);
    ast.addImport("keyword", keyword);

    const parser = b.addModule("parser", .{
        .root_source_file = b.path("lib/parser/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser.addImport("diag", diag);
    parser.addImport("keyword", keyword);
    parser.addImport("lexer", lexer);
    parser.addImport("ast", ast);

    const interp = b.addModule("interp", .{
        .root_source_file = b.path("lib/interp/interp.zig"),
        .target = target,
        .optimize = optimize,
    });
    interp.addImport("diag", diag);
    interp.addImport("ast", ast);
    interp.addImport("lexer", lexer);
    interp.addImport("parser", parser);

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("diag", diag);
    main_mod.addImport("keyword", keyword);
    main_mod.addImport("lexer", lexer);
    main_mod.addImport("ast", ast);
    main_mod.addImport("parser", parser);
    main_mod.addImport("interp", interp);

    const exe = b.addExecutable(.{
        .name = "morphlc",
        .root_module = main_mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run morphlc").dependOn(&run.step);

    // `zig build test` runs every module's tests. Each module is also testable
    // directly, e.g. `zig test -Mroot=lib/lexer/lexer.zig ...` — but the
    // import wiring makes `zig build test` the path of least friction.
    const test_step = b.step("test", "Run all tests");
    for ([_]*std.Build.Module{ diag, keyword, lexer, ast, parser, interp, main_mod }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        const mod_run = b.addRunArtifact(t);
        // From the build root, so a test may read a source file by path — the
        // root-block agreement test reads `stage1/infer.mpl`.
        mod_run.setCwd(b.path("."));
        test_step.dependOn(&mod_run.step);
    }

    // STYLE.md's mechanical rules over stage 1's morphl source: no tabs, no trailing
    // whitespace, 100 columns with a string literal's contents exempt. Side effects,
    // because the `.mpl` files are not declared inputs and a cached pass would outlive
    // an edit — the same reason every stage-1 step has them.
    const style_exe = b.addExecutable(.{
        .name = "stylecheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/stylecheck.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const style_run = b.addRunArtifact(style_exe);
    style_run.setCwd(b.path("."));
    style_run.addArgs(&.{ "stage1", "stage1/fixtures" });
    style_run.has_side_effects = true;
    const style_step = b.step("test-style", "Check stage 1's morphl source against STYLE.md");
    style_step.dependOn(&style_run.step);
    test_step.dependOn(&style_run.step);

    // Stage 1's own tests, written in morphl and run by stage 0. They read
    // their own source by path, so the run has to happen from the build root.
    // Debug is ~9x slower than ReleaseFast here; for real stage-1 work build
    // with `-Doptimize=ReleaseFast`.
    const stage1_step = b.step("test-stage1", "Run stage 1's morphl tests under stage 0");
    for ([_][]const u8{
        "stage1/lexer_test.mpl",
        "stage1/parser_test.mpl",
        "stage1/types_test.mpl",
        "stage1/infer_test.mpl",
        "stage1/ir_test.mpl",
        "stage1/lower_test.mpl",
        "stage1/emit_test.mpl",
        "stage1/compiler_test.mpl",
    }) |suite| {
        const suite_run = b.addRunArtifact(exe);
        suite_run.addArgs(&.{ "--run", suite });
        suite_run.setCwd(b.path("."));
        suite_run.expectExitCode(0);
        // The suite reads its `.mpl` sources at *run* time, so the build graph
        // does not know they are inputs and would serve a cached success after
        // stage 1 changed. These are tests; running them every time is right.
        suite_run.has_side_effects = true;
        stage1_step.dependOn(&suite_run.step);
        test_step.dependOn(&suite_run.step);
    }

    // `tyio` writes a type down and reads it back, which is what a per-module
    // interface cache rests on. The property is checked against *real* type tables
    // rather than hand-written cases: a lowered module interns the μ types, the big
    // unions, the de Bruijn binders and the prop-bearing blocks that only arise from
    // real source, and `T.same` is the right equality because `intern` keys on it.
    //
    // Two modules, chosen for coverage rather than size: `types.mpl` has the
    // recursive type language and `emit.mpl` the widest tables (230 types) of
    // anything that lowers quickly under stage 0.
    for ([_][]const u8{ "stage1/types.mpl", "stage1/emit.mpl" }) |tyio_target| {
        const rt = b.addRunArtifact(exe);
        rt.addArgs(&.{ "--run", "stage1/tyio_test.mpl", tyio_target });
        rt.setCwd(b.path("."));
        rt.expectExitCode(0);
        rt.has_side_effects = true;
        stage1_step.dependOn(&rt.step);
        test_step.dependOn(&rt.step);
    }

    // The round trip stage 2 will need: morphl → C → binary → the right answer.
    // Compiled at -O0 on purpose, so that a tail call surviving as a call would
    // overflow rather than be optimised into a loop behind our backs — the loop
    // has to be ours (§6a).
    const emit_step = b.step("test-emit", "Compile each fixture to C, build it, run it");
    const run0_step = b.step("test-run0", "Run each fixture under stage 0 and check it answers as compiled");
    // `host` is an extra C file linked in beside the emitted one: §4.16's fixture
    // needs C functions to bind, and providing them here is the point — a symbol
    // from libc proves nothing about a signature the target supplies itself.
    for ([_]struct { src: []const u8, want: []const u8, host: ?[]const u8 = null }{
        .{ .src = "stage1/fixtures/fact.mpl", .want = "3628800\n" },
        .{ .src = "stage1/fixtures/blocks.mpl", .want = "16\n" },
        .{ .src = "stage1/fixtures/strings.mpl", .want = "hello, world! 9 a\n" },
        .{ .src = "stage1/fixtures/storage.mpl", .want = "154\n" },
        .{ .src = "stage1/fixtures/match.mpl", .want = "25\n" },
        .{ .src = "stage1/fixtures/closures.mpl", .want = "42\n" },
        .{ .src = "stage1/fixtures/try.mpl", .want = "5\n" },
        .{ .src = "stage1/fixtures/mutual.mpl", .want = "1\n" },
        .{ .src = "stage1/fixtures/mutual_sig.mpl", .want = "9\n" },
        .{ .src = "stage1/fixtures/unions.mpl", .want = "91\n" },
        .{ .src = "stage1/fixtures/props.mpl", .want = "169\n" },
        .{ .src = "stage1/fixtures/template.mpl", .want = "43\n" },
        .{ .src = "stage1/fixtures/import.mpl", .want = "57\n" },
        .{ .src = "stage1/fixtures/list.mpl", .want = "20\n" },
        .{ .src = "stage1/fixtures/group.mpl", .want = "49\n" },
        .{ .src = "stage1/fixtures/coerce.mpl", .want = "321\n" },
        .{ .src = "stage1/fixtures/scope.mpl", .want = "17\n" },
        .{ .src = "stage1/fixtures/alloc.mpl", .want = "41\n" },
        .{ .src = "stage1/fixtures/option.mpl", .want = "52\n" },
        .{ .src = "stage1/fixtures/mutual_import.mpl", .want = "5\n" },
        .{ .src = "stage1/fixtures/prop_union.mpl", .want = "9\n" },
        // §3.3's top-level `$prop`s. All four shapes §1.1 allows, because each takes a
        // different route through `lower_prop_*`: a scalar is read off the type, a
        // prop-only block and a `$func` keep their source, and a `$template` is what
        // `$specialize` consumes. 58, and before the fix this did not lower at all.
        .{ .src = "stage1/fixtures/topprop.mpl", .want = "58\n" },
        // An **empty** module is a valid empty block (§3.3, §2.1), not an error. Both
        // passes flattened §8's `read_file` option to a string, so a file that could not
        // be read and a file that is empty were one case. 9.
        .{ .src = "stage1/fixtures/empty_import.mpl", .want = "9\n" },
        .{ .src = "stage1/fixtures/effect.mpl", .want = "46\n" },
        .{ .src = "stage1/fixtures/init_order.mpl", .want = "106\n" },
        .{ .src = "stage1/fixtures/alias.mpl", .want = "42\n" },
        .{ .src = "stage1/fixtures/tramp.mpl", .want = "21\n" },
        .{ .src = "stage1/fixtures/extern.mpl", .want = "185\n",
           .host = "stage1/fixtures/extern_host.c" },
        .{ .src = "stage1/fixtures/arrays.mpl", .want = "12\n" },
        .{ .src = "stage1/fixtures/write.mpl", .want = "161\n" },
        .{ .src = "stage1/fixtures/fwd_init.mpl", .want = "126\n" },
        .{ .src = "stage1/fixtures/module_value.mpl", .want = "41\n" },
        .{ .src = "stage1/fixtures/prop_param.mpl", .want = "98\n" },
        .{ .src = "stage1/fixtures/defaults.mpl", .want = "247\n" },
        .{ .src = "stage1/fixtures/init_fwd.mpl", .want = "22\n" },
        // §4.9's instance semantics for a template body with `$decl`s: storage per
        // evaluation, an argument evaluated once, props shared. 140.
        .{ .src = "stage1/fixtures/instance.mpl", .want = "140\n" },
        // The generic in type-only positions inside the `$decl`s, through the real
        // prelude's `list`. 6.
        .{ .src = "stage1/fixtures/instance_list.mpl", .want = "6\n" },
        // §4.9's self-specialisation, in the entry file and in a module member, and a
        // prop whose value is its own specialisation. 21.
        .{ .src = "stage1/fixtures/selfspec.mpl", .want = "21\n" },
        // §4.9's compile-time generics: a value in the type, and tags made by a
        // template. 61.
        .{ .src = "stage1/fixtures/ctgen.mpl", .want = "61\n" },
        // §4.10's receiver: top level, a member taken as a value, a block local to a
        // function, `$mut` storage, and a copy. 48.
        .{ .src = "stage1/fixtures/receiver.mpl", .want = "48\n" },
        // §6's trait objects: coercion at a call and at `$set`, `$traitsof` of a name, of
        // `$mut` storage and of an expression, `$impl` over an `Int`, and `$match` on an
        // object. 87.
        .{ .src = "stage1/fixtures/traits.mpl", .want = "87\n" },
        // ...and across a module boundary, the table in the shared header. 49.
        .{ .src = "stage1/fixtures/traits_split.mpl", .want = "49\n" },
        // §4.8's `$overload`: first fit, a nested overload, an overload argument, and
        // `x.i`. 362.
        .{ .src = "stage1/fixtures/overload.mpl", .want = "362\n" },
    }) |fixture| {
        // Every fixture twice: once straight, once with §9.2's pass in the
        // middle. The answer has to be the same both ways — that is the whole
        // claim, from either side. "The compiler never assumes a pass ran", so
        // `emit_c` must be right on unoptimised input; a pass may not change
        // what the program means, so `opt_c` must agree with it.
        for ([_][]const u8{ "stage1/emit_c.mpl", "stage1/opt_c.mpl" }) |driver| {
            const emit_run = b.addRunArtifact(exe);
            emit_run.addArgs(&.{ "--run", driver, fixture.src });
            emit_run.setCwd(b.path("."));
            // Same reason as above: the compiler is stage-1 source read at run
            // time, so a cached run would compile the previous compiler.
            emit_run.has_side_effects = true;
            const c_file = emit_run.captureStdOut(.{ .basename = "out.c" });

            // A compiler legitimately emits a static function nothing calls;
            // the rest of -Werror is worth keeping.
            const cc = b.addSystemCommand(&.{ "cc", "-O0", "-Wall", "-Wno-unused-function", "-Werror", "-o" });
            const bin = cc.addOutputFileArg("fixture");
            cc.addFileArg(c_file);
            if (fixture.host) |h| cc.addFileArg(b.path(h));

            const run_bin = std.Build.Step.Run.create(b, "run the emitted binary");
            run_bin.addFileArg(bin);
            run_bin.expectStdOutEqual(fixture.want);
            emit_step.dependOn(&run_bin.step);
            test_step.dependOn(&run_bin.step);
        }

        // ...and once more under stage 0, which must give the same answer. The two are
        // independent implementations of one language, so agreeing on what a program
        // *means* is the strongest check either has; `--main` makes stage 0 call the
        // file's `main` and print it as the emitted `main` does. A fixture with a C host
        // needs `$extern`, which stage 0 leaves out of the subset (BOOTSTRAP.md §1.2).
        if (fixture.host == null) {
            const run0 = b.addRunArtifact(exe);
            run0.addArgs(&.{ "--run", "--main", fixture.src });
            run0.setCwd(b.path("."));
            run0.has_side_effects = true;
            run0.expectStdOutEqual(fixture.want);
            run0_step.dependOn(&run0.step);
            test_step.dependOn(&run0.step);
        }
    }
    // ------------------------------------------------- programs that must fail
    //
    // Every other fixture is a program that must *work*; these must be refused,
    // by both implementations. Stage 1 must report each listed diagnostic, line
    // and column included, and exactly that many; stage 0 must refuse to run the
    // program. Both halves matter, for the reason `fwd_uninit.mpl` exists: a
    // program stage 0 refuses and the checker accepts is one the compiled backend
    // gives a meaning stage 0 never would.
    const reject_step = b.step("test-reject", "Check that programs which must fail are refused by both stages");
    for ([_]struct { src: []const u8, stage1: []const []const u8, count: []const u8, stage0: []const u8 }{
        .{
            .src = "stage1/fixtures/fwd_uninit.mpl",
            .stage1 = &.{
                "fwd_uninit.mpl:14:1: 'f' is read before the $decl completing its $fwd has run",
                "fwd_uninit.mpl:20:1: 'v' is read before the $decl completing its $fwd has run",
                "fwd_uninit.mpl:23:1: 'v' is read before the $decl completing its $fwd has run",
            },
            .count = "errors: 3\n",
            .stage0 = "is not initialized yet",
        },
    }) |bad| {
        const s1 = b.addRunArtifact(exe);
        s1.addArgs(&.{ "--run", "stage1/typecheck.mpl", bad.src });
        s1.setCwd(b.path("."));
        s1.has_side_effects = true;
        for (bad.stage1) |m| s1.expectStdOutMatch(m);
        s1.expectStdOutMatch(bad.count);
        reject_step.dependOn(&s1.step);
        test_step.dependOn(&s1.step);

        const s0 = b.addRunArtifact(exe);
        s0.addArgs(&.{ "--run", bad.src });
        s0.setCwd(b.path("."));
        s0.has_side_effects = true;
        s0.expectStdErrMatch(bad.stage0);
        s0.expectExitCode(1);
        reject_step.dependOn(&s0.step);
        test_step.dependOn(&s0.step);
    }

    // ---------------------------------------------------------------- stage 2
    //
    // `bootstrap/mplc.c` is stage 1 emitted by stage 1 — BOOTSTRAP's stage 2 —
    // and it is committed on purpose. Regenerating it from stage 0 costs ~90
    // minutes; `cc` costs seconds. That is the usual bootstrap trade, and the
    // alternative is worse: the fast compiler would exist only on whichever
    // machine last built it, which is exactly where it was before this step.
    const stage2_step = b.step("stage2", "Build mplc from the committed bootstrap C");
    // `-Wno-unused-but-set-variable` for §7.8's `⊥`: a `panic`'s result gets a
    // temporary that is assigned and never read, because nothing after a `panic`
    // runs. Correct C for the construct, so it is silenced rather than worked
    // around — same judgement as `-Wno-unused-function` for the fixtures.
    const mplc_cc = b.addSystemCommand(&.{
        "cc", "-O2", "-Wall", "-Wno-unused-function", "-Wno-unused-but-set-variable", "-o",
    });
    const mplc_bin = mplc_cc.addOutputFileArg("mplc");
    mplc_cc.addFileArg(b.path("bootstrap/mplc.c"));
    stage2_step.dependOn(&b.addInstallBinFile(mplc_bin, "mplc").step);

    // ------------------------------------------------- §9.1's list of outputs
    //
    // `emit` answers one output per module (§9.1), and the point of that is a file
    // per source module that compiles on its own — so this builds a program the way
    // a real build would: write the outputs, compile each *separately*, link them.
    //
    // It is the only step that can find a linkage mistake. `test-emit` concatenates
    // everything into one translation unit, where a symbol that should have been
    // external is indistinguishable from one that is `static`; `verify` cannot see
    // linkage at all. Three bugs were found exactly here, all of them references
    // `mpl_init` makes that no walk over function bodies can see.
    //
    // No `#include` is emitted — §9 makes the build a program, so how a target
    // invokes its C compiler is the build's business — hence `-include mpl.h` below.
    //
    // The expected file list is declared rather than globbed, which also pins the
    // partition: if `emit` stopped giving a module its own output, this fails.
    const split_step = b.step("test-split", "Build a program from one C file per module");
    {
        // The writing driver, compiled: §8's `write_file` is emitted, so a compiled
        // driver can put each output where its `path` says. Under stage 0 it could
        // not — `--run` never calls `main`, which is where a compiled driver's work
        // has to live, or the link fails for want of `main`.
        const ef_emit = std.Build.Step.Run.create(b, "mplc emits the writing driver");
        ef_emit.addFileArg(mplc_bin);
        ef_emit.addArg("stage1/emit_files.mpl");
        ef_emit.setCwd(b.path("."));
        ef_emit.has_side_effects = true;
        const ef_c = ef_emit.captureStdOut(.{ .basename = "emit_files.c" });
        const ef_cc = b.addSystemCommand(&.{ "cc", "-O2", "-w", "-o" });
        const ef_bin = ef_cc.addOutputFileArg("emit_files");
        ef_cc.addFileArg(ef_c);

        for ([_]struct { src: []const u8, want: []const u8, mods: []const []const u8 }{
            // Two modules and a global read across the boundary.
            .{ .src = "stage1/fixtures/import.mpl", .want = "57\n", .mods = &.{"import_util"} },
            // §3.3's effects, which is what per-module initialisers are for: each
            // module runs its own, in §4.10's order, and the answer pins the order.
            // Three outputs, not two: `effect_util` imports the prelude, so that is a
            // module of this program too. Declaring the list rather than globbing is what
            // caught the omission — `prelude.c` was written and never compiled, and the
            // link failed on `mpl_fprelude_4`.
            .{ .src = "stage1/fixtures/effect.mpl", .want = "46\n", .mods = &.{ "prelude", "effect_util" } },
            // A cycle between two module members (§5.5), so each is named from the
            // other's output.
            .{ .src = "stage1/fixtures/mutual_import.mpl", .want = "5\n", .mods = &.{"mutual_util"} },
            // A module's record is a static in the importer's output initialised from
            // globals in the module's, so this is the fixture where that has to link.
            .{ .src = "stage1/fixtures/module_value.mpl", .want = "41\n", .mods = &.{ "modval_inner", "modval_util" } },
            // A prop read off a parameter is lowered where it is written and called from
            // the reader's output, so this is where that has to link.
            .{ .src = "stage1/fixtures/prop_param.mpl", .want = "98\n", .mods = &.{ "prelude", "prop_param_util" } },
            // A wrapper lives in its callee's output and is called from the caller's.
            .{ .src = "stage1/fixtures/defaults.mpl", .want = "247\n", .mods = &.{ "prelude", "defaults_util" } },
            // A module's initialiser is its own output's, so source order has to hold there.
            .{ .src = "stage1/fixtures/init_fwd.mpl", .want = "22\n", .mods = &.{"init_fwd_util"} },
            // §6's tables are static in the shared header, and their shims call members
            // defined in the module's own output — so they must be external there.
            .{ .src = "stage1/fixtures/traits_split.mpl", .want = "49\n", .mods = &.{"traits_util"} },
        }) |fx| {
            const write = std.Build.Step.Run.create(b, "emit one output per module");
            write.addFileArg(ef_bin);
            write.addArg(fx.src);
            const dir = write.addOutputDirectoryArg("split");
            write.setCwd(b.path("."));
            write.has_side_effects = true;

            const link = b.addSystemCommand(&.{ "cc", "-o" });
            const prog = link.addOutputFileArg("prog");

            // Every module's output, plus the entry file's, each its own translation
            // unit. `-w` because a compiler emits statics nothing calls, and here
            // every file sees the whole header.
            var names = std.ArrayList([]const u8).initCapacity(b.allocator, fx.mods.len + 1) catch @panic("OOM");
            for (fx.mods) |m| names.appendAssumeCapacity(b.fmt("{s}.c", .{m}));
            names.appendAssumeCapacity("main.c");
            for (names.items) |name| {
                const cc = b.addSystemCommand(&.{ "cc", "-O0", "-w", "-include" });
                cc.addFileArg(dir.path(b, "mpl.h"));
                cc.addArgs(&.{ "-c", "-o" });
                const obj = cc.addOutputFileArg(b.fmt("{s}.o", .{name}));
                cc.addFileArg(dir.path(b, name));
                link.addFileArg(obj);
            }

            const run_split = std.Build.Step.Run.create(b, "run the separately built program");
            run_split.addFileArg(prog);
            run_split.expectStdOutEqual(fx.want);
            split_step.dependOn(&run_split.step);
            test_step.dependOn(&run_split.step);
        }
    }

    // ------------------------------------------- a module's output is its own
    //
    // §4.14 makes a projection onto a module the only way to name a function across
    // that edge, so a function's C linkage is decidable from the function alone —
    // which is what makes a module's emitted text a function of its own source, and
    // therefore cacheable per module. This is the check on that claim: two programs
    // importing one module, differing only in which of its members the *entry file*
    // calls, must produce a byte-identical output for it.
    //
    // It replaces a rule that asked whether some other module named a function. That
    // was finer — fewer exports — and being finer was the defect: `stable_b` calling
    // one extra prelude member flipped it from `static` to external and rewrote
    // `prelude.c` from outside prelude. `test-split` cannot see this (it only asks
    // whether the program links) and neither can `test-emit` (it concatenates).
    //
    // Under stage 0, not `mplc`, because it is `stage1/` that is being checked and a
    // committed binary predates the change by construction.
    const stable_step = b.step("test-stable", "One module, three programs, identical output");
    {
        var outs: [3]std.Build.LazyPath = undefined;
        for ([_][]const u8{ "stable_a", "stable_b", "stable_c" }, 0..) |name, i| {
            const one = std.Build.Step.Run.create(b, b.fmt("emit prelude.c for {s}", .{name}));
            one.addFileArg(exe.getEmittedBin());
            one.addArgs(&.{ "--run", "stage1/emit_one.mpl", b.fmt("stage1/fixtures/{s}.mpl", .{name}), "prelude.c" });
            one.setCwd(b.path("."));
            one.has_side_effects = true;
            outs[i] = one.captureStdOut(.{ .basename = b.fmt("{s}.prelude.c", .{name}) });
        }
        // `stable_b` differs from `stable_a` only in which prelude member the entry
        // file calls, which is the **linkage** property. `stable_c` reaches the prelude
        // *through another module* instead of directly, which is the **naming**
        // property: every counter in lowering is at a different value by the time the
        // prelude is lowered, so this fails for any identity still drawn from one.
        for ([_]usize{ 1, 2 }) |i| {
            const same = b.addSystemCommand(&.{"cmp"});
            same.addFileArg(outs[0]);
            same.addFileArg(outs[i]);
            stable_step.dependOn(&same.step);
            test_step.dependOn(&same.step);
        }
    }

    // ------------------------------------ a compile-time identity is its source
    //
    // §4.10's prop values and §4.9's template ids end up in a module's *interface*,
    // so a per-module cache can only hit if they are a function of the source rather
    // than of what the checker happened to reach first. `ct_id` makes them so; this
    // is the check.
    //
    // **One module, two importing programs.** `ifm.mpl` carries both identities
    // inference mints — a `$func`-valued prop's `cv_opaque` and a `$template`'s id —
    // and both entry files import it; `iface_d.mpl` first imports `ifx.mpl`, which
    // mints some of each. Its serialised interface must come out byte-identical.
    //
    // An earlier version compared a prop declared in *each* of the two fixtures, which
    // cannot work: an identity derives from the file's short name, so two files differ
    // by design. It passed only because `check_source`'s arguments were swapped, which
    // made `cx.file` the shared directory — the guard was an artifact of the same bug
    // it was meant to catch. Against the pre-fix compiler this one reads `listM16 o28`
    // against `listM11 o33`; with the fix the two interfaces are equal.
    //
    // Reading it is possible at all because an `$import`'s field type *is* the
    // module's interface — `iface_dump.mpl` prints that field and nothing else, since
    // the output is compared byte for byte.
    const iface_step = b.step("test-iface", "A compile-time identity is independent of load order");
    {
        var ids: [2]std.Build.LazyPath = undefined;
        for ([_][]const u8{ "iface_c", "iface_d" }, 0..) |name, i| {
            const dump = b.addRunArtifact(exe);
            dump.addArgs(&.{ "--run", "stage1/iface_dump.mpl", b.fmt("stage1/fixtures/{s}.mpl", .{name}), "M" });
            dump.setCwd(b.path("."));
            dump.has_side_effects = true;
            ids[i] = dump.captureStdOut(.{ .basename = b.fmt("{s}.id", .{name}) });
        }
        const same = b.addSystemCommand(&.{"cmp"});
        same.addFileArg(ids[0]);
        same.addFileArg(ids[1]);
        iface_step.dependOn(&same.step);
        test_step.dependOn(&same.step);
    }

    const s2_step = b.step("test-stage2", "mplc against stage 0, and the committed C against itself");

    // **The guard against `bootstrap/mplc.c` rotting.** The committed C has to be
    // what the compiler it builds emits for its own source. Change `stage1/` and
    // forget to regenerate, and this is what says so — otherwise the committed C
    // silently drifts behind the tree it claims to be.
    {
        const emit = std.Build.Step.Run.create(b, "mplc emits its own source");
        emit.addFileArg(mplc_bin);
        emit.addArg("stage1/mplc.mpl");
        emit.setCwd(b.path("."));
        // stage-1 sources are read at *run* time, so a cached run would compile
        // the previous compiler — the same reason the suites above say this.
        emit.has_side_effects = true;
        const fresh = emit.captureStdOut(.{ .basename = "mplc.c" });
        const same = b.addSystemCommand(&.{"cmp"});
        same.addFileArg(fresh);
        same.addFileArg(b.path("bootstrap/mplc.c"));
        s2_step.dependOn(&same.step);
        test_step.dependOn(&same.step);
    }

    // The strongest check in the project, and now cheap enough to be routine:
    // two independent executions of the same stage-1 source — one interpreted by
    // stage 0, one compiled to native code — must agree on every byte of a real
    // output. These fixtures are chosen because they emit *no* diagnostics, so
    // both sides write pure C and are directly comparable; `emit_c.mpl` prints
    // diagnostics to stdout ahead of the C, and `mplc` prints only the C.
    for ([_][]const u8{
        "stage1/fixtures/arrays.mpl",
        "stage1/fixtures/list.mpl",
        "stage1/fixtures/match.mpl",
        // §6a's general case, where the two implementations have the most room
        // to disagree: the group function's parameter list is every member's
        // concatenated, so an ordering difference would show here and nowhere else.
        "stage1/fixtures/mutual_sig.mpl",
        // §6a's indirect case resolved through an alias, where the two
        // implementations could disagree about which target a thunk names.
        "stage1/fixtures/alias.mpl",
        // §6a's indirect case: the pending block's tag is an interned type
        // index, so the two implementations must agree on the whole type table
        // for the emitted trampoline to match.
        "stage1/fixtures/tramp.mpl",
        // §4.16: the declarations and wrappers are derived from the signature's
        // interned type, so this compares the ABI mapping on both sides.
        "stage1/fixtures/extern.mpl",
        // §8's `write_file` answers `<unit, err>` with both members nullary, so which
        // position each takes comes from the call site's interned union (§7.5) — the
        // two implementations have to agree about that, not just about the bytes.
        "stage1/fixtures/write.mpl",
        // §4.9: an instance's arguments sit in slots of an outer block and its body in
        // the current frame, so both sides must agree on the slot numbering.
        "stage1/fixtures/instance.mpl",
        // §4.10: a member that names its receiver is a closure over it, so the two
        // implementations must agree on the captures and on the entry point driving §6a.
        "stage1/fixtures/receiver.mpl",
        // §6: the shims and tables are emitted from a walk over every body, so the two
        // must find the same implementations in the same order.
        "stage1/fixtures/traits.mpl",
        // §4.8: lowering resolves an overload with its own types, as inference did.
        "stage1/fixtures/overload.mpl",
    }) |src| {
        const by_mplc = std.Build.Step.Run.create(b, "mplc emits the fixture");
        by_mplc.addFileArg(mplc_bin);
        by_mplc.addArg(src);
        by_mplc.setCwd(b.path("."));
        by_mplc.has_side_effects = true;
        const a = by_mplc.captureStdOut(.{ .basename = "by_mplc.c" });

        const by_s0 = b.addRunArtifact(exe);
        by_s0.addArgs(&.{ "--run", "stage1/emit_c.mpl", src });
        by_s0.setCwd(b.path("."));
        by_s0.has_side_effects = true;
        const bfile = by_s0.captureStdOut(.{ .basename = "by_stage0.c" });

        const agree = b.addSystemCommand(&.{"cmp"});
        agree.addFileArg(a);
        agree.addFileArg(bfile);
        s2_step.dependOn(&agree.step);
        test_step.dependOn(&agree.step);
    }

    // `mplc` reports a non-fatal diagnostic on stderr and keeps stdout the C. It could
    // not before — §8 gave a program stdout and `panic`, and a warning on stdout would
    // corrupt the artifact — so emit's diagnostics were computed and dropped. A library
    // is the case every build hits: "no top-level `$decl` named `main`" is not an error
    // for one, and must arrive as a warning with exit 0.
    {
        const warn = std.Build.Step.Run.create(b, "mplc warns on stderr");
        warn.addFileArg(mplc_bin);
        warn.addArg("stage1/fixtures/import_util.mpl");
        warn.setCwd(b.path("."));
        warn.has_side_effects = true;
        warn.expectStdErrMatch("stage1/fixtures/import_util.mpl: warning: no top-level $decl named 'main'\n");
        warn.expectExitCode(0);
        s2_step.dependOn(&warn.step);
        test_step.dependOn(&warn.step);
    }

    // ---------------------------------------------------------------- paranoid
    //
    // `T.same` answers by interned class (INTERNING.md), and a class is only right while
    // each constructor's key mirrors `same_deep` exactly. Nothing else notices if one
    // stops: the answers are wrong only for the pairs a gap merges, and the emitted C stays
    // plausible. So the whole compiler is compiled with every comparison checked against
    // the structural reference, and any **merge** — two types `same_deep` calls different
    // in one class — fails the step. It was shown to bite: with field names dropped from
    // the block key it reported 46,903 merges and exited 134. About a minute, most of it
    // the reference walks that class comparison exists to avoid.
    const paranoid_step = b.step("test-paranoid", "Check every class comparison against same_deep over the whole compiler");
    {
        const emit = std.Build.Step.Run.create(b, "mplc emits the paranoid driver");
        emit.addFileArg(mplc_bin);
        emit.addArg("stage1/paranoid.mpl");
        emit.setCwd(b.path("."));
        emit.has_side_effects = true;
        const c_file = emit.captureStdOut(.{ .basename = "paranoid.c" });

        const cc = b.addSystemCommand(&.{ "cc", "-O2", "-w", "-o" });
        const bin = cc.addOutputFileArg("paranoid");
        cc.addFileArg(c_file);

        const pz_run = std.Build.Step.Run.create(b, "paranoid over the compiler");
        pz_run.addFileArg(bin);
        pz_run.addArg("stage1/mplc.mpl");
        pz_run.setCwd(b.path("."));
        pz_run.has_side_effects = true;
        pz_run.expectStdOutMatch(" 0 merges, ");
        pz_run.expectExitCode(0);
        paranoid_step.dependOn(&pz_run.step);
        test_step.dependOn(&pz_run.step);
    }

    // ---------------------------------------------- the suites, compiled
    //
    // `test-stage1` runs the morphl suites under the interpreter. This runs the same
    // suites *compiled*: `mplc` emits each one, `cc` builds it, and it runs. That
    // exercises what the interpreter cannot — the compiled front end, which is what
    // `mplc` actually is — on 400-odd checks written for something else, the way
    // `cc` on the whole compiler has repeatedly found what the morphl suites missed.
    // Five of the eight could not even be emitted until §3.4's defaults were supplied
    // at a short call; they were rejected by `verify`.
    //
    // A suite has no `main`: its checks are top-level effects (§3.3), which run from
    // `mpl_init`. So the driver includes the emitted C and supplies a `main` that runs
    // the initialiser — `mpl_init` is `static`, which is why it is an `#include`
    // rather than a second translation unit — and defines `mpl_argc`/`mpl_argv`, which
    // the runtime declares `extern` and the backend defines only beside a real `main`.
    //
    // A failing check panics, so the exit status is the verdict. The last line is
    // matched too, because a suite that stopped early would also exit 0 and nothing
    // else would say so. It is the suite's final section's line, so a new section at
    // the end of a suite means updating it here.
    const compiled_step = b.step("test-compiled-suites", "Compile each stage-1 suite with mplc and run it");
    for ([_]struct { src: []const u8, last: []const u8 }{
        .{ .src = "stage1/lexer_test.mpl", .last = "all lexer tests passed\n" },
        .{ .src = "stage1/parser_test.mpl", .last = "all parser tests passed\n" },
        .{ .src = "stage1/types_test.mpl", .last = "all class-key tests passed\n" },
        .{ .src = "stage1/infer_test.mpl", .last = "all overload tests passed\n" },
        .{ .src = "stage1/ir_test.mpl", .last = "all typed-tree tests passed\n" },
        .{ .src = "stage1/lower_test.mpl", .last = "all lowering tests passed\n" },
        .{ .src = "stage1/emit_test.mpl", .last = "all C backend tests passed\n" },
        .{ .src = "stage1/compiler_test.mpl", .last = "all pipeline tests passed\n" },
    }) |suite| {
        const emit = std.Build.Step.Run.create(b, "mplc emits the suite");
        emit.addFileArg(mplc_bin);
        emit.addArg(suite.src);
        emit.setCwd(b.path("."));
        emit.has_side_effects = true;
        const c_file = emit.captureStdOut(.{ .basename = "suite.c" });

        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(c_file, "suite.c");
        const driver = wf.add("main.c",
            \\#include "suite.c"
            \\int mpl_argc = 0;
            \\char **mpl_argv = 0;
            \\int main(int argc, char **argv) {
            \\  mpl_argc = argc;
            \\  mpl_argv = argv;
            \\  mpl_init();
            \\  return 0;
            \\}
            \\
        );

        // -O0: these are big translation units (a suite imports the module it tests
        // and that module's whole closure), and the run is seconds either way.
        const cc = b.addSystemCommand(&.{ "cc", "-O0", "-w", "-o" });
        const bin = cc.addOutputFileArg("suite");
        cc.addFileArg(driver);

        const run_suite = std.Build.Step.Run.create(b, "run the compiled suite");
        run_suite.addFileArg(bin);
        run_suite.setCwd(b.path("."));
        run_suite.has_side_effects = true;
        run_suite.expectExitCode(0);
        run_suite.expectStdOutMatch(suite.last);
        compiled_step.dependOn(&run_suite.step);
        test_step.dependOn(&run_suite.step);
    }

}
