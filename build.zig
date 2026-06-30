const std = @import("std");

/// Which board we are building firmware for.
const Board = enum { pico, pico2 };

/// On the RP2350 (Pico 2) each core can boot as an ARM Cortex-M33 or a RISC-V
/// Hazard3. This selects which one we target. Ignored for the RP2040 (Pico),
/// which is always ARM Cortex-M0+.
const Arch = enum { arm, riscv };

pub fn build(b: *std.Build) void {
    // ----------------------------------------------------------------------
    // Build options
    // ----------------------------------------------------------------------
    const board = b.option(Board, "board", "Target board: pico (RP2040) or pico2 (RP2350) [default: pico]") orelse .pico;
    const arch = b.option(Arch, "arch", "RP2350 core architecture: arm or riscv [default: arm]") orelse .arm;
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    // The firmware target is derived from the board/arch
    const target = b.resolveTargetQuery(firmwareQuery(board, arch));

    // ----------------------------------------------------------------------
    // The one and only library module.
    // ----------------------------------------------------------------------
    const pico_zdk = b.addModule("pico_zdk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ----------------------------------------------------------------------
    // Examples - auto-discovered from examples/<name>/main.zig.
    //
    //   zig build <name>                     build one example by name
    //   zig build examples                   build every example
    // ----------------------------------------------------------------------
    const examples_step = b.step("examples", "Build all examples");

    const io = b.graph.io;
    var examples_dir = b.build_root.handle.openDir(io, "examples", .{ .iterate = true }) catch |err| {
        std.debug.panic("failed to open examples/ directory: {s}", .{@errorName(err)});
    };
    defer examples_dir.close(io);

    var it = examples_dir.iterate();
    while (it.next(io) catch @panic("failed to iterate examples/")) |entry| {
        if (entry.kind != .directory) continue;

        // Skip directories that don't actually contain an example entry point.
        examples_dir.access(io, b.fmt("{s}/main.zig", .{entry.name}), .{}) catch continue;

        const name = b.dupe(entry.name);
        const main_path = b.fmt("examples/{s}/main.zig", .{name});
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(main_path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "pico_zdk", .module = pico_zdk },
                },
            }),
        });
        // Bare-metal firmware: the reset handler is the entry point, and there
        // is no host runtime to pull in.
        exe.entry = .{ .symbol_name = "_start" };

        const install = b.addInstallArtifact(exe, .{});

        // Per-example step: `zig build blinky`.
        const one = b.step(name, b.fmt("Build the '{s}' example", .{name}));
        one.dependOn(&install.step);

        examples_step.dependOn(&install.step);
    }

    // The default `zig build` (the install step) builds every example.
    b.getInstallStep().dependOn(examples_step);

    // ----------------------------------------------------------------------
    // Tests - host-runnable, hardware-independent logic only.
    //
    // Tests must run on the build host, so they use the native target rather
    // than the firmware target
    // ----------------------------------------------------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const mod_tests = b.addTest(.{ .root_module = test_mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run host unit tests");
    test_step.dependOn(&run_mod_tests.step);
}

fn firmwareQuery(board: Board, arch: Arch) std.Target.Query {
    return switch (board) {
        // RP2040: dual ARM Cortex-M0+, no FPU → soft-float EABI.
        .pico => .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m0plus },
            .os_tag = .freestanding,
            .abi = .eabi,
        },
        .pico2 => switch (arch) {
            // RP2350 ARM: Cortex-M33 with single-precision FPU → hard-float EABI.
            .arm => .{
                .cpu_arch = .thumb,
                .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
                .os_tag = .freestanding,
                .abi = .eabihf,
            },
            // RP2350 RISC-V: Hazard3 is RV32IMAC + Zicsr/Zifencei.
            .riscv => .{
                .cpu_arch = .riscv32,
                .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
                .cpu_features_add = std.Target.riscv.featureSet(&.{ .m, .a, .c, .zicsr, .zifencei }),
                .os_tag = .freestanding,
                .abi = .eabi,
            },
        },
    };
}
