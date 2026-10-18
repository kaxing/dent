const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "dent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .error_tracing = false,
        }),
    });

    const zstd_dep = b.dependency("zstd", .{ .target = target, .optimize = optimize });
    const translator: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translator.linkLibrary(zstd_dep.artifact("zstd"));
    exe.root_module.addImport("c", translator.mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run dent");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const hash_mod = b.createModule(.{ .root_source_file = b.path("src/hash.zig") });

    const chunker_mod = b.createModule(.{ .root_source_file = b.path("src/chunker.zig") });

    const tree_module = b.createModule(.{ .root_source_file = b.path("src/tree.zig") });
    tree_module.addImport("hash.zig", hash_mod);

    const compress_mod = b.createModule(.{ .root_source_file = b.path("src/compress.zig"), .link_libc = true, .target = target });
    compress_mod.addImport("c", translator.mod);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test-coverage/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addImport("hash", hash_mod);
    unit_tests.root_module.addImport("chunker", chunker_mod);
    unit_tests.root_module.addImport("tree", tree_module);
    unit_tests.root_module.addImport("compress", compress_mod);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
