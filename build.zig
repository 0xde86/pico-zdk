const std = @import("std");

/// UF2 format constants and family IDs, shared with the `elf2uf2` host tool in
/// tools/uf2/. Imported here only for the `FamilyId` enum used to tag builds;
/// the conversion itself is done by running that tool (see `hostTool`).
const uf2 = @import("tools/uf2/uf2.zig");

/// Which board we are building firmware for.
pub const Board = enum { pico, pico2 };

/// On the RP2350 (Pico 2) each core can boot as an ARM Cortex-M33 or a RISC-V
/// Hazard3. This selects which one we target. Ignored for the RP2040 (Pico),
/// which is always ARM Cortex-M0+.
pub const Arch = enum { arm, riscv };

/// Standard Zig build entry point: wires up the library module, examples, and
/// tests for the board/arch selected by the `-Dboard`/`-Darch` options.
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
    // The main library module.
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
    //
    // The examples/ directory only exists when this package is built
    // standalone. A downstream consumer fetches pico_zdk through the package
    // manager, examples/ is absent there.
    // ----------------------------------------------------------------------
    const io = b.graph.io;
    if (b.build_root.handle.openDir(io, "examples", .{ .iterate = true })) |dir| {
        var examples_dir = dir;
        defer examples_dir.close(io);

        const examples_step = b.step("examples", "Build all examples");

        // Host tool that repacks a firmware ELF as a drag-and-drop UF2. Built
        // once here and re-run (with per-example args) inside the loop below.
        const uf2_tool = buildTool(b, b.path("tools/uf2/main.zig"), "elf2uf2");

        var it = examples_dir.iterate();
        while (it.next(io) catch @panic("failed to iterate examples/")) |entry| {
            if (entry.kind != .directory) continue;

            // Skip directories that don't contain an example entry point. Only a
            // missing main.zig is expected; permission or I/O failures are real
            // problems and should surface rather than being silently skipped.
            examples_dir.access(io, b.fmt("{s}/main.zig", .{entry.name}), .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => std.debug.panic("failed to probe examples/{s}/main.zig: {s}", .{ entry.name, @errorName(err) }),
            };

            const name = b.dupe(entry.name);
            const main_path = b.fmt("examples/{s}/main.zig", .{name});

            const fw = addFirmware(b, pico_zdk, .{
                .name = name,
                .root_source_file = b.path(main_path),
                .board = board,
                .arch = arch,
                .optimize = optimize,
            });

            const suffix = targetSuffix(b, board, arch);
            const elf_name = b.fmt("{s}-{s}", .{ name, suffix });
            const uf2_name = b.fmt("{s}-{s}.uf2", .{ name, suffix });

            const install = b.addInstallBinFile(fw.getEmittedBin(), elf_name);

            const uf2_run = b.addRunArtifact(uf2_tool);
            uf2_run.addArg(@tagName(uf2FamilyId(board, arch)));
            uf2_run.addFileArg(fw.getEmittedBin());
            const uf2_path = uf2_run.addOutputFileArg(uf2_name);
            const install_uf2 = b.addInstallBinFile(uf2_path, uf2_name);

            // Per-example step: `zig build blinky`.
            const one = b.step(name, b.fmt("Build the '{s}' example", .{name}));
            one.dependOn(&install.step);
            one.dependOn(&install_uf2.step);

            examples_step.dependOn(&install.step);
            examples_step.dependOn(&install_uf2.step);
        }

        // The default `zig build` (the install step) builds every example.
        b.getInstallStep().dependOn(examples_step);
    } else |err| switch (err) {
        // No examples/ directory (e.g. consumed as a dependency): nothing to do.
        error.FileNotFound => {},
        else => std.debug.panic("failed to open examples/ directory: {s}", .{@errorName(err)}),
    }

    // ----------------------------------------------------------------------
    // Tests - host-runnable, hardware-independent logic.
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
    addToolTest(b, test_step, b.path("tools/uf2/uf2.zig"), optimize);
    addToolTest(b, test_step, b.path("tools/boot2_image/boot2_crc.zig"), optimize);
}

fn buildTool(b: *std.Build, root_source_file: std.Build.LazyPath, name: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = root_source_file,
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
}

fn addToolTest(b: *std.Build, test_step: *std.Build.Step, root_source_file: std.Build.LazyPath, optimize: std.builtin.OptimizeMode) void {
    const module = b.createModule(.{
        .root_source_file = root_source_file,
        .target = b.graph.host,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
}

/// UF2 family ID for the selected board/arch, so the BOOTSEL bootloader only
/// accepts an image built for the matching chip and core.
fn uf2FamilyId(board: Board, arch: Arch) uf2.FamilyId {
    return switch (board) {
        .pico => .rp2040,
        .pico2 => switch (arch) {
            .arm => .rp2350_arm_s,
            .riscv => .rp2350_riscv,
        },
    };
}

fn targetSuffix(b: *std.Build, board: Board, arch: Arch) []const u8 {
    return switch (board) {
        .pico => "pico",
        .pico2 => b.fmt("pico2-{s}", .{@tagName(arch)}),
    };
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
            // RP2350 RISC-V: Hazard3
            .riscv => .{
                .cpu_arch = .riscv32,
                .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
                .cpu_features_add = std.Target.riscv.featureSet(&.{ .a, .m, .c, .zba, .zbb, .zbs, .zcb, .zcmp, .zbkb, .zicsr, .zifencei }),
                .os_tag = .freestanding,
                .abi = .eabi,
            },
        },
    };
}

/// Helper to build pico/pico2 firmware. Pass the `pico_zdk` module to link
/// against: this package's own module internally, or `dep.module("pico_zdk")`
/// from a downstream `build.zig`.
pub fn addFirmware(b: *std.Build, pico_zdk: *std.Build.Module, opts: struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    board: Board = .pico,
    arch: Arch = .arm,
    optimize: std.builtin.OptimizeMode = .ReleaseSmall,
}) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(firmwareQuery(opts.board, opts.arch));
    const app = b.createModule(.{
        .root_source_file = opts.root_source_file,
        .target = target,
        .optimize = opts.optimize,
        .imports = &.{.{ .name = "pico_zdk", .module = pico_zdk }},
    });

    const rt_options = b.addOptions();
    rt_options.addOption(Board, "board", opts.board);
    rt_options.addOption(Arch, "arch", opts.arch);

    const src_dir = pico_zdk.root_source_file.?.dirname();
    const package_root = src_dir.dirname();
    const runtime = b.createModule(.{
        .root_source_file = src_dir.path(b, "rt/runtime.zig"),
        .target = target,
        .optimize = opts.optimize,
        .single_threaded = true,
        .stack_check = false,
        .stack_protector = false,
        .unwind_tables = .none,
        .error_tracing = false,
        .imports = &.{.{ .name = "app", .module = app }},
    });
    runtime.addOptions("rt_config", rt_options);

    if (opts.board == .pico) {
        runtime.addImport("boot2_image", createBoot2ImageModule(b, package_root));
    }

    const exe = b.addExecutable(.{ .name = opts.name, .root_module = runtime });
    exe.entry = .{ .symbol_name = "_start" };
    exe.link_gc_sections = true;
    exe.bundle_ubsan_rt = false;
    exe.setLinkerScript(src_dir.path(b, switch (opts.board) {
        .pico => "rt/rp2040.ld",
        .pico2 => "rt/rp2350.ld",
    }));
    return exe;
}

/// Links the RP2040 second stage in SRAM5, then generates the checksummed
/// 256-byte flash image as a Zig module consumed by the firmware runtime.
fn createBoot2ImageModule(b: *std.Build, package_root: std.Build.LazyPath) *std.Build.Module {
    const target = b.resolveTargetQuery(firmwareQuery(.pico, .arm));
    const rt_dir = package_root.path(b, "src/rt");

    const boot2 = b.addExecutable(.{
        .name = "pico_zdk_boot2",
        .root_module = b.createModule(.{
            .root_source_file = rt_dir.path(b, "boot2.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .strip = true,
            .stack_check = false,
            .stack_protector = false,
            .unwind_tables = .none,
            .error_tracing = false,
        }),
    });
    boot2.entry = .{ .symbol_name = "_start" };
    boot2.link_gc_sections = true;
    boot2.bundle_compiler_rt = false;
    boot2.bundle_ubsan_rt = false;
    boot2.setLinkerScript(rt_dir.path(b, "boot2_rp2040.ld"));

    // Run the host tool to checksum the boot2 image and emit a Zig module.
    // The tool's args are: <input.elf> <output.zig>.
    const boot2_tool = buildTool(b, package_root.path(b, "tools/boot2_image/main.zig"), "boot2_image");
    const boot2_run = b.addRunArtifact(boot2_tool);
    boot2_run.addFileArg(boot2.getEmittedBin());
    const generated_source = boot2_run.addOutputFileArg("boot2_image.zig");

    return b.createModule(.{
        .root_source_file = generated_source,
        .target = target,
        .optimize = .ReleaseSmall,
    });
}
