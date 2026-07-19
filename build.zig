const std = @import("std");

/// UF2 format constants and family IDs, shared with the `elf2uf2` host tool in
/// tools/uf2/. Imported here only for the `FamilyId` enum used to tag builds;
/// the conversion itself is done by running that tool (see `buildTool`).
const uf2 = @import("tools/uf2/uf2.zig");

/// This file as a type, so `Sdk.init` can locate the pico-zdk dependency in a
/// consumer's build graph regardless of the name it was given in build.zig.zon.
const this_build_zig = @This();

/// Input option to select board we are building firmware for. User-facing axis (`-Dboard`).
pub const Board = enum { pico, pico2 };

/// Input option to select core on the RP2350 (Pico 2): ARM Cortex-M33 or a RISC-V
/// Hazard3. User-facing axis (`-Darch`); an explicit `riscv` on an RP2040 board fails
/// at configuration time.
pub const Arch = enum { arm, riscv };

/// SoC mounted on the selected board. Derived axis carried by `zdk_config`:
/// chip facts (register layout, boot metadata format) branch on this.
pub const Chip = enum { rp2040, rp2350 };

/// CPU core the firmware boots on. Derived axis carried by `zdk_config`:
/// target resolution and the runtime's start path branch on this.
pub const Core = enum { cortex_m0plus, cortex_m33, hazard3 };

/// The derived configuration axes, resolved exactly once by `resolveConfig`.
/// Downstream code branches on the axis it means - `board` for PCB wiring,
/// `chip` for SoC facts, `core` for CPU facts - instead of re-deriving one
/// axis from another.
const Config = struct {
    board: Board,
    chip: Chip,
    core: Core,
};

/// A configured firmware's linked ELF and drag-and-drop UF2 image.
///
/// Both outputs are derived from the same executable and `Sdk` configuration,
/// so the UF2 family ID cannot disagree with the linked target.
pub const Firmware = struct {
    /// Builder that owns the output and installation steps.
    b: *std.Build,
    /// Artifact base name, also used for the installed UF2 filename.
    name: []const u8,
    /// Linked bare-metal executable.
    elf: *std.Build.Step.Compile,
    /// UF2 image generated from `elf`, suitable for the BOOTSEL drive.
    uf2: std.Build.LazyPath,

    /// Adds both the ELF and UF2 image to the consumer's install step.
    pub fn install(firmware: *const Firmware) void {
        firmware.installTo(firmware.b.getInstallStep());
    }

    /// Installs the ELF (as `<name>`) and the UF2 image (as `<name>.uf2`)
    /// into the binary install directory and attaches both to `step`.
    pub fn installTo(firmware: *const Firmware, step: *std.Build.Step) void {
        const b = firmware.b;
        const install_elf = b.addInstallBinFile(firmware.elf.getEmittedBin(), firmware.name);
        const install_uf2 = b.addInstallBinFile(firmware.uf2, b.fmt("{s}.uf2", .{firmware.name}));
        step.dependOn(&install_elf.step);
        step.dependOn(&install_uf2.step);
    }
};

/// A configured firmware-building capability. Captures the validated
/// board/arch selection, the resolved target, the library module, and the
/// single resolved configuration module once, so one firmware cannot combine a
/// library module and a target that disagree.
pub const Sdk = struct {
    /// Builder that owns the firmware modules and artifacts: the consumer's
    /// builder, or this package's own when building standalone.
    b: *std.Build,
    /// This package's builder; owns the paths into src/ and tools/.
    zdk: *std.Build,
    config: Config,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    /// The configured library module every firmware links against.
    module: *std.Build.Module,
    /// The resolved `config` module shared by the library and the runtime.
    /// It is the sole importer of the generated `zdk_config` options module.
    config_module: *std.Build.Module,
    /// Checksummed RP2040 second-stage bootloader image; null on RP2350.
    boot2_image: ?*std.Build.Module,
    /// Host tool that converts linked firmware ELFs to UF2 images.
    uf2_tool: *std.Build.Step.Compile,

    pub const Options = struct {
        board: Board,
        /// RP2350 core architecture. Unset defaults to ARM on RP2350 boards;
        /// an explicit `.riscv` on an RP2040 board is a configure-time error.
        arch: ?Arch = null,
        optimize: std.builtin.OptimizeMode = .ReleaseSmall,
    };

    /// Entry point for a downstream build.zig:
    ///
    ///     const pico_zdk = @import("pico_zdk");
    ///
    ///     const sdk = pico_zdk.Sdk.init(b, .{ .board = .pico, ... });
    ///     const firmware = sdk.addFirmware(.{
    ///         .name = "my_firmware",
    ///         .root_source_file = b.path("src/main.zig"),
    ///     });
    ///     firmware.install();
    ///
    /// Reuse one `Sdk` for several programs on one platform; create another
    /// `Sdk` for another platform.
    pub fn init(b: *std.Build, opts: Options) *Sdk {
        const dep = b.dependencyFromBuildZig(this_build_zig, .{});
        return create(dep.builder, b, opts);
    }

    /// Builds one firmware ELF and its matching UF2 image for this SDK's
    /// platform. Everything besides the program itself - target,
    /// configuration, runtime, linker script, boot metadata, and UF2 family -
    /// is owned by the `Sdk`, so it cannot drift per firmware.
    pub fn addFirmware(sdk: *Sdk, opts: struct {
        name: []const u8,
        root_source_file: std.Build.LazyPath,
    }) *Firmware {
        const b = sdk.b;
        const app = b.createModule(.{
            .root_source_file = opts.root_source_file,
            .target = sdk.target,
            .optimize = sdk.optimize,
            .imports = &.{.{ .name = "pico_zdk", .module = sdk.module }},
        });

        const runtime = b.createModule(.{
            .root_source_file = sdk.zdk.path("src/rt/runtime.zig"),
            .target = sdk.target,
            .optimize = sdk.optimize,
            .single_threaded = true,
            .stack_check = false,
            .stack_protector = false,
            .unwind_tables = .none,
            .error_tracing = false,
            .imports = &.{
                .{ .name = "app", .module = app },
                .{ .name = "config", .module = sdk.config_module },
            },
        });
        if (sdk.boot2_image) |boot2_image| {
            runtime.addImport("boot2_image", boot2_image);
        }

        const exe = b.addExecutable(.{ .name = opts.name, .root_module = runtime });
        exe.entry = .{ .symbol_name = "_start" };
        exe.link_gc_sections = true;
        exe.bundle_ubsan_rt = false;
        exe.setLinkerScript(sdk.zdk.path(switch (sdk.config.chip) {
            .rp2040 => "src/rt/rp2040.ld",
            .rp2350 => "src/rt/rp2350.ld",
        }));

        const uf2_run = b.addRunArtifact(sdk.uf2_tool);
        uf2_run.addArg(@tagName(uf2Family(sdk.config)));
        uf2_run.addFileArg(exe.getEmittedBin());
        const uf2_path = uf2_run.addOutputFileArg(b.fmt("{s}.uf2", .{opts.name}));

        const firmware = b.allocator.create(Firmware) catch @panic("OOM");
        firmware.* = .{
            .b = b,
            .name = b.dupe(opts.name),
            .elf = exe,
            .uf2 = uf2_path,
        };
        return firmware;
    }
};

/// Standard Zig build entry point: wires up the examples and tests for the
/// board/arch selected by the `-Dboard`/`-Darch` options.
pub fn build(b: *std.Build) void {
    // ----------------------------------------------------------------------
    // Build options
    // ----------------------------------------------------------------------
    const board = b.option(Board, "board", "Target board: pico (RP2040) or pico2 (RP2350) [default: pico]") orelse .pico;
    const arch = b.option(Arch, "arch", "RP2350 core architecture: arm or riscv [default: arm on RP2350 boards]");
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    // Zig's incremental ZCU cache can retain target-specific state when the
    // same build is re-run for another CPU architecture. Keep the regular
    // content-addressed build cache, but default firmware builds to the stable
    // whole-compilation cache mode. An explicit `-fincremental` still wins.
    if (b.dep_prefix.len == 0 and b.graph.incremental == null) {
        b.graph.incremental = false;
    }

    // The standalone Sdk instance behind the examples. It must not create a
    // dependency on this package itself, so it calls the common constructor
    // directly; consumers go through `Sdk.init`.
    const sdk = create(b, b, .{ .board = board, .arch = arch, .optimize = optimize });

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

            const firmware = sdk.addFirmware(.{
                .name = b.fmt("{s}-{s}", .{ name, targetSuffix(sdk.config) }),
                .root_source_file = b.path(main_path),
            });

            // Per-example step: `zig build blinky`.
            const one = b.step(name, b.fmt("Build the '{s}' example", .{name}));
            firmware.installTo(one);
            examples_step.dependOn(one);
        }

        // The default `zig build` (the install step) builds every example.
        b.getInstallStep().dependOn(examples_step);
    } else |err| switch (err) {
        // No examples/ directory (e.g. consumed as a dependency): nothing to do.
        error.FileNotFound => {},
        else => std.debug.panic("failed to open examples/ directory: {s}", .{@errorName(err)}),
    }

    // ----------------------------------------------------------------------
    // Tests - host-runnable, hardware-independent logic. The library suite is
    // instantiated under BOTH chip configurations, so chip selection and every
    // comptime branch are analyzed for both chips regardless of `-Dboard`.
    // ----------------------------------------------------------------------
    const test_step = b.step("test", "Run host unit tests");
    addHostTests(b, test_step, optimize, .pico, null);
    addHostTests(b, test_step, optimize, .pico2, .arm);
    addToolTest(b, test_step, b.path("tools/uf2/uf2.zig"), optimize);
    addToolTest(b, test_step, b.path("tools/boot2_image/boot2_crc.zig"), optimize);
    addBuildApiTest(b, test_step);
}

/// Common Sdk constructor behind both the standalone `build` and consumer
/// `Sdk.init`. `zdk_b` is this package's own builder (source of src/ and
/// tools/ paths); `user_b` is the builder that owns the resulting steps,
/// modules, and artifacts. Standalone, the two are the same builder.
fn create(zdk_b: *std.Build, user_b: *std.Build, opts: Sdk.Options) *Sdk {
    const config = resolveConfig(opts.board, opts.arch);
    const target = user_b.resolveTargetQuery(firmwareQuery(config.core));
    const generated_config = generatedConfigModule(user_b, config);
    const config_module = user_b.createModule(.{
        .root_source_file = zdk_b.path("src/config.zig"),
        .target = target,
        .optimize = opts.optimize,
        .imports = &.{.{ .name = "zdk_config", .module = generated_config }},
    });

    const module = user_b.createModule(.{
        .root_source_file = zdk_b.path("src/root.zig"),
        .target = target,
        .optimize = opts.optimize,
        .imports = &.{.{ .name = "config", .module = config_module }},
    });

    const sdk = user_b.allocator.create(Sdk) catch @panic("OOM");
    sdk.* = .{
        .b = user_b,
        .zdk = zdk_b,
        .config = config,
        .optimize = opts.optimize,
        .target = target,
        .module = module,
        .config_module = config_module,
        .boot2_image = if (config.chip == .rp2040) createBoot2ImageModule(user_b, zdk_b) else null,
        .uf2_tool = buildTool(user_b, zdk_b.path("tools/uf2/main.zig"), "elf2uf2"),
    };
    return sdk;
}

/// Resolves the user-facing (board, arch) pair into the derived axes. The
/// single owner of the board→chip→core relationship: no later code switches
/// on independent board/arch values, and the one invalid combination fails
/// here, at configure time.
fn resolveConfig(board: Board, arch: ?Arch) Config {
    switch (board) {
        .pico => {
            if (arch == .riscv) {
                std.log.err("pico (RP2040) has no RISC-V cores; the arch option (-Darch) applies only to RP2350 boards", .{});
                std.process.exit(1);
            }
            // An explicit `-Darch=arm` is accepted: it is true.
            return .{ .board = .pico, .chip = .rp2040, .core = .cortex_m0plus };
        },
        .pico2 => return .{
            .board = .pico2,
            .chip = .rp2350,
            .core = switch (arch orelse .arm) {
                .arm => .cortex_m33,
                .riscv => .hazard3,
            },
        },
    }
}

/// Emits one `zdk_config` options module carrying the derived axes. An `Sdk`
/// shares a single instance between its library and runtime modules; host
/// tests create their own per configuration.
fn generatedConfigModule(b: *std.Build, config: Config) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(Board, "board", config.board);
    options.addOption(Chip, "chip", config.chip);
    options.addOption(Core, "core", config.core);
    return options.createModule();
}

/// Adds one host-target instantiation of the library test suite under the
/// given board/arch configuration.
fn addHostTests(b: *std.Build, test_step: *std.Build.Step, optimize: std.builtin.OptimizeMode, board: Board, arch: ?Arch) void {
    const config = resolveConfig(board, arch);
    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "zdk_config", .module = generatedConfigModule(b, config) }},
    });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "config", .module = config_module }},
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_mod })).step);
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

/// Runs a real downstream build that imports pico-zdk under a renamed
/// dependency key and creates firmware for two different platforms in one
/// build graph. This exercises `Sdk.init`, which standalone builds bypass.
///
/// The step must always re-run: a cached Run step keys only on its argv and
/// declared file inputs, and none of this package's sources are inputs, so a
/// cached green result would go stale the moment the build API breaks. The
/// re-run stays fast because the fixture's cache and install prefix live at a
/// stable path under this build's cache root, keeping it incremental.
fn addBuildApiTest(b: *std.Build, test_step: *std.Build.Step) void {
    const scratch = b.pathFromRoot(b.cache_root.join(b.allocator, &.{"build_api_test"}) catch @panic("OOM"));

    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setCwd(b.path("tools/build_api_test/fixture"));
    run.has_side_effects = true;
    run.addArgs(&.{ "--cache-dir", b.pathJoin(&.{ scratch, "cache" }) });
    run.addArgs(&.{ "--prefix", b.pathJoin(&.{ scratch, "install" }) });
    test_step.dependOn(&run.step);
}

/// UF2 family ID for the configuration, so the BOOTSEL bootloader only
/// accepts an image built for the matching chip and core.
fn uf2Family(config: Config) uf2.FamilyId {
    return switch (config.core) {
        .cortex_m0plus => .rp2040,
        .cortex_m33 => .rp2350_arm_s,
        .hazard3 => .rp2350_riscv,
    };
}

/// Output-name suffix reflecting the user-facing axes.
fn targetSuffix(config: Config) []const u8 {
    return switch (config.board) {
        .pico => "pico",
        .pico2 => switch (config.core) {
            .cortex_m33 => "pico2-arm",
            .hazard3 => "pico2-riscv",
            .cortex_m0plus => unreachable, // excluded by resolveConfig
        },
    };
}

fn firmwareQuery(core: Core) std.Target.Query {
    return switch (core) {
        // RP2040: dual ARM Cortex-M0+, no FPU → soft-float EABI.
        .cortex_m0plus => .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m0plus },
            .os_tag = .freestanding,
            .abi = .eabi,
        },
        // RP2350 ARM: Cortex-M33 with single-precision FPU → hard-float EABI.
        .cortex_m33 => .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
            .os_tag = .freestanding,
            .abi = .eabihf,
        },
        // RP2350 RISC-V: Hazard3
        .hazard3 => .{
            .cpu_arch = .riscv32,
            .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
            .cpu_features_add = std.Target.riscv.featureSet(&.{ .a, .m, .c, .zba, .zbb, .zbs, .zcb, .zcmp, .zbkb, .zicsr, .zifencei }),
            .os_tag = .freestanding,
            .abi = .eabi,
        },
    };
}

/// Links the RP2040 second stage in SRAM5, then generates the checksummed
/// 256-byte flash image as a Zig module consumed by the firmware runtime.
fn createBoot2ImageModule(user_b: *std.Build, zdk_b: *std.Build) *std.Build.Module {
    const target = user_b.resolveTargetQuery(firmwareQuery(.cortex_m0plus));

    const boot2 = user_b.addExecutable(.{
        .name = "pico_zdk_boot2",
        .root_module = user_b.createModule(.{
            .root_source_file = zdk_b.path("src/rt/boot2.zig"),
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
    boot2.setLinkerScript(zdk_b.path("src/rt/boot2_rp2040.ld"));

    // Run the host tool to checksum the boot2 image and emit a Zig module.
    // The tool's args are: <input.elf> <output.zig>.
    const boot2_tool = buildTool(user_b, zdk_b.path("tools/boot2_image/main.zig"), "boot2_image");
    const boot2_run = user_b.addRunArtifact(boot2_tool);
    boot2_run.addFileArg(boot2.getEmittedBin());
    const generated_source = boot2_run.addOutputFileArg("boot2_image.zig");

    return user_b.createModule(.{
        .root_source_file = generated_source,
        .target = target,
        .optimize = .ReleaseSmall,
    });
}
