const std = @import("std");

pub fn build(b: *std.Build) void {
    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
    });

    const unit_tests = b.addTest(.{
        .root_module = main_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const lexer_test_module = b.createModule(.{
        .root_source_file = b.path("lib/lexer/lexer.zig"),
        .target = b.graph.host,
    });

    const lexer_tests = b.addTest(.{
        .root_module = lexer_test_module,
    });

    const run_lexer_tests = b.addRunArtifact(lexer_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_lexer_tests.step);

    const exe = b.addExecutable(.{
        .name = "morphlc",
        .root_module = main_module,
    });

    const lexer = b.addModule("lexer", . {
        .root_source_file = b.path("lib/lexer/lexer.zig"),
    });

    exe.root_module.addImport("lexer", lexer);

    b.installArtifact(exe);
}
