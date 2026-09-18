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
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Stage 1's own tests, written in morphl and run by stage 0. They read
    // their own source by path, so the run has to happen from the build root.
    // Debug is ~9x slower than ReleaseFast here; for real stage-1 work build
    // with `-Doptimize=ReleaseFast`.
    const stage1_step = b.step("test-stage1", "Run stage 1's morphl tests under stage 0");
    for ([_][]const u8{ "stage1/lexer_test.mpl", "stage1/parser_test.mpl" }) |suite| {
        const suite_run = b.addRunArtifact(exe);
        suite_run.addArgs(&.{ "--run", suite });
        suite_run.setCwd(b.path("."));
        suite_run.expectExitCode(0);
        stage1_step.dependOn(&suite_run.step);
        test_step.dependOn(&suite_run.step);
    }
}
