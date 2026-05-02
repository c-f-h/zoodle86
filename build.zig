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
    kernel_module.addIncludePath(b.path("."));
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

    const kernel_step = b.step("kernel", "Build build/kernel.elf and build/kernel.full.elf");
    kernel_step.dependOn(&write_kernel_full.step);
    kernel_step.dependOn(&write_kernel.step);

    const kernel_full_step = b.step("kernel-full", "Build build/kernel.full.elf");
    kernel_full_step.dependOn(&write_kernel_full.step);

    b.default_step = kernel_step;
}
