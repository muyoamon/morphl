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

    // The round trip stage 2 will need: morphl → C → binary → the right answer.
    // Compiled at -O0 on purpose, so that a tail call surviving as a call would
    // overflow rather than be optimised into a loop behind our backs — the loop
    // has to be ours (§6a).
    const emit_step = b.step("test-emit", "Compile each fixture to C, build it, run it");
    for ([_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "stage1/fixtures/fact.mpl", .want = "3628800\n" },
        .{ .src = "stage1/fixtures/blocks.mpl", .want = "16\n" },
        .{ .src = "stage1/fixtures/strings.mpl", .want = "hello, world! 9 a\n" },
        .{ .src = "stage1/fixtures/storage.mpl", .want = "154\n" },
        .{ .src = "stage1/fixtures/match.mpl", .want = "25\n" },
        .{ .src = "stage1/fixtures/closures.mpl", .want = "42\n" },
        .{ .src = "stage1/fixtures/try.mpl", .want = "5\n" },
        .{ .src = "stage1/fixtures/mutual.mpl", .want = "1\n" },
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
        .{ .src = "stage1/fixtures/effect.mpl", .want = "46\n" },
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

            const run_bin = std.Build.Step.Run.create(b, "run the emitted binary");
            run_bin.addFileArg(bin);
            run_bin.expectStdOutEqual(fixture.want);
            emit_step.dependOn(&run_bin.step);
            test_step.dependOn(&run_bin.step);
        }
    }
}
