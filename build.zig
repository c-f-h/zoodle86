// This exists only for ZLS compatibility - use SCons instead.
const std = @import("std");

const default_nasm_search_paths = [_][]const u8{
    "C:\\Program Files\\nasm-3.01",
};

const default_strip_search_paths = [_][]const u8{
    "C:\\Program Files\\mingw64\\bin",
};

/// Build the freestanding kernel ELF using the same target, entry point, and linker script as SCons.
pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode for the kernel-only build",
    ) orelse .ReleaseSmall;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const nasm = b.findProgram(&.{"nasm"}, &default_nasm_search_paths) catch
        @panic("nasm executable not found; add it to PATH or install it in C:\\Program Files\\nasm-3.01");
    const strip = b.findProgram(&.{"strip"}, &default_strip_search_paths) catch
        @panic("strip executable not found; add it to PATH or install it in C:\\Program Files\\mingw64\\bin");

    const assemble_interrupts = b.addSystemCommand(&.{ nasm, "-f", "elf32" });
    assemble_interrupts.addFileArg(b.path("kernel/interrupts.asm"));
    assemble_interrupts.addArg("-o");
    const interrupts_obj = assemble_interrupts.addOutputFileArg("interrupts.o");

    const kernel_module = b.addModule("kernel", .{
        .root_source_file = b.path("kernel/kernel.zig"),
        .target = target,
        .optimize = optimize,
        .stack_protector = false,
        .strip = false,
    });
    const abi_module = b.addModule("abi", .{
        .root_source_file = b.path("common/abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel_module.addIncludePath(b.path("."));
    kernel_module.addImport("abi", abi_module);
    kernel_module.addObjectFile(interrupts_obj);

    const kernel_full = b.addExecutable(.{
        .name = "kernel.full.elf",
        .root_module = kernel_module,
    });
    kernel_full.bundle_compiler_rt = false;
    kernel_full.entry = .{ .symbol_name = "kernel_init" };
    kernel_full.setLinkerScript(b.path("kernel.ld"));

    const strip_kernel = b.addSystemCommand(&.{ strip, "--strip-all" });
    strip_kernel.addFileArg(kernel_full.getEmittedBin());
    strip_kernel.addArg("-o");
    const kernel = strip_kernel.addOutputFileArg("kernel.elf");

    const write_kernel_full = b.addUpdateSourceFiles();
    write_kernel_full.addCopyFileToSource(kernel_full.getEmittedBin(), "build/kernel.full.elf");

    const write_kernel = b.addUpdateSourceFiles();
    write_kernel.addCopyFileToSource(kernel, "build/kernel.elf");

    // Build PureDOOM as a userspace ELF (PureDOOM engine + Zig entry point).
    // Use a generated .c copy (Zig treats .h build targets as PCH).
    const doom_c_gen = b.addWriteFiles();
    const doom_c_path = doom_c_gen.addCopyFile(b.path("opt/PureDOOM/PureDOOM.h"), "doom_impl.c");

    const doom_module = b.createModule(.{
        .root_source_file = b.path("userspace/doom_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    doom_module.addCSourceFile(.{
        .file = doom_c_path,
        .flags = &.{
            "-std=c99",
            "-DDOOM_IMPLEMENTATION",
            "-Wno-parentheses",
            "-Wno-enum-compare",
            "-Wno-deprecated-non-prototype",
        },
    });
    doom_module.addIncludePath(b.path("opt/PureDOOM"));
    doom_module.addImport("abi", abi_module);

    const doom_exe = b.addExecutable(.{
        .name = "doom.elf",
        .root_module = doom_module,
    });
    doom_exe.setLinkerScript(b.path("userspace.ld"));
    doom_exe.entry = .{ .symbol_name = "_start" };
    doom_exe.bundle_compiler_rt = false;

    const write_doom = b.addUpdateSourceFiles();
    write_doom.addCopyFileToSource(doom_exe.getEmittedBin(), "build/doom.elf");
    write_doom.addCopyFileToSource(doom_exe.getEmittedBin(), "static/bin/doom");

    const doom_step = b.step("doom", "Build PureDOOM userspace ELF");
    doom_step.dependOn(&write_doom.step);

    const kernel_step = b.step("kernel", "Build build/kernel.elf and build/kernel.full.elf");
    kernel_step.dependOn(&write_kernel_full.step);
    kernel_step.dependOn(&write_kernel.step);

    const kernel_full_step = b.step("kernel-full", "Build build/kernel.full.elf");
    kernel_full_step.dependOn(&write_kernel_full.step);

    b.default_step = kernel_step;
}
