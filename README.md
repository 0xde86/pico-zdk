# pico-zdk

> A from-scratch re-implementation of the Raspberry Pi Pico SDK in **Zig** - a *Zig Development Kit* for the RP2040 and RP2350.

`pico-zdk` is my personal learning project with only two goals:

1. **Better understand the hardware.** Drive both Pico, Pico 2 boards at the lowest possible level - by implementing all the drivers myself, instead of calling into the C SDK.
2. **Learn Zig.** Build a real, non-trivial library that follows Zig idioms and reads like the Zig standard library.

This is **not** a binding to `pico-sdk`. There is no C. Everything - startup code, vector tables, linker layout, register definitions, and drivers - is written in Zig and cross-compiled to bare metal.

> ⚠️ **Status: early / experimental.** Expect breaking changes on every commit until the API stabilizes.

---

## Why Zig?

What I like the most in zig - it is it's explicitness and simplicity. You want allocation - pass an allocator to a function. You want to handle errors - return error type. No hidden control flows, no magic. No complex meta languages (templates, macros, ...). 

### What is particularly good for this project

**Cross-compilation is built in.** No external toolchain; `zig build` cross-compiles to `thumb-freestanding` (M0+/M33) and `riscv32-freestanding` (Hazard3) out of the box.

## Project layout

```
build.zig            Build graph: board/arch target selection, examples, tests
build.zig.zon        Package manifest (name: pico_zdk, min Zig 0.16.0)
src/
  root.zig           Public API surface - the single library module's root
examples/
  minimal/main.zig   Smallest firmware that builds for the target
  blinky/main.zig    LED blink example (placeholder for now)
```

As the SDK grows, `src/` will be organized roughly mirroring the hardware:

```
src/
  root.zig           Re-exports the public API
  chip/              Chip-specific code (rp2040 / rp2350) and definitions
  hal/               Hardware abstraction: gpio, clocks, uart, spi, i2c, pwm, adc, dma, pio
  rt/                Runtime: startup, vector table, linker scripts, bootrom interface
  drivers/           Higher-level on-board / common peripheral drivers
```

## Requirements

**Zig 0.16.0**.

## Building

```sh
# Build all examples for the default board (RP2040 / Cortex-M0+)
zig build examples

# Build a single example
zig build blinky

# Run the host-side unit tests
zig build test
```

The target CPU is chosen with `-Dboard` / `-Darch` (defaults: `pico`, `arm`):

```sh
zig build -Dboard=pico                  # RP2040,  thumb   / Cortex-M0+
zig build -Dboard=pico2                 # RP2350,  thumb   / Cortex-M33
zig build -Dboard=pico2 -Darch=riscv    # RP2350,  riscv32 / Hazard3
```

## Using it as a dependency

Once published, add it with:

```sh
zig fetch --save git+https://github.com/0xde86/pico-zdk
```

This adds a `pico_zdk` entry to your `build.zig.zon` `dependencies`.

### The `addFirmware` build helper (recommended)

`pico-zdk`'s `build.zig` exports a helper that builds a firmware executable for
you: it resolves the bare-metal target from `board`/`arch`, sets the `_start`
entry point, and links the `pico_zdk` module. Import the dependency's
`build.zig` namespace with `@import("pico_zdk")` and call it:

```zig
const std = @import("std");
const pico_zdk = @import("pico_zdk");

pub fn build(b: *std.Build) void {
    const board: pico_zdk.Board = .pico2; // .pico (default) or .pico2
    const arch: pico_zdk.Arch = .arm;     // .arm (default) or .riscv, for pico2 only
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    // The same board/arch select the target for both the pico_zdk module and
    // your firmware exe, so they always match.
    const dep = b.dependency("pico_zdk", .{
        .board = board,
        .arch = arch,
        .optimize = optimize,
    });

    const fw = pico_zdk.addFirmware(b, dep.module("pico_zdk"), .{
        .name = "my_firmware",
        .root_source_file = b.path("src/main.zig"),
        .board = board,
        .arch = arch,
        .optimize = optimize,
    });

    b.addInstallArtifact(fw, .{});
}
```

`@import("pico_zdk")` gives you the build-time decls (`Board`, `Arch`,
`addFirmware`); `dep.module("pico_zdk")` gives you the library module to link.

### Wiring it manually

If you'd rather not use the helper, import the module directly and configure the
target yourself:

```zig
const pico = b.dependency("pico_zdk", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pico_zdk", pico.module("pico_zdk"));
exe.entry = .{ .symbol_name = "_start" }; // bare-metal: reset handler is the entry point
```

## Design principles

I want to to try to implement it the way so it feels like the Zig standard library, and not like a 1:1 port of the C SDK:

- **Canonical Zig APIs.** `init`/`deinit`, explicit error sets, options structs with defaults, `*std.Io.Writer` for output.
- **Comptime-first configuration.** Pin maps and peripheral setup are checked at compile time wherever possible.
- **Datasheet-accurate registers.** Each peripheral's registers are `packed struct(u32)` whose fields match the RP2040/RP2350 datasheets, accessed through `volatile`.
- **Zero hidden cost.** No allocator is required for the core HAL; anything that allocates takes an `Allocator` explicitly.

## References

- [Raspberry Pi RP2040 datasheet](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf)
- [Raspberry Pi RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
- [Official C/C++ `pico-sdk`](https://github.com/raspberrypi/pico-sdk)
- [MicroZig](https://github.com/ZigEmbeddedGroup/microzig) - the Zig Embedded Group's bare-metal framework; a useful study of MMIO and register-generation patterns in Zig

## License

All code in this repository is licensed under GNU LESSER GENERAL PUBLIC LICENSE Version 3. As I believe that freedom must be sustained. 
