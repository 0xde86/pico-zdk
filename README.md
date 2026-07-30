# pico-zdk

> A from-scratch re-implementation of the Raspberry Pi Pico SDK in **Zig** - a *Zig Development Kit* for the RP2040 and RP2350.

`pico-zdk` is my personal learning project with only two goals:

1. **Better understand the hardware.** Drive both Pico, Pico 2 boards at the lowest possible level - by implementing all the drivers myself, instead of calling into the C SDK.
2. **Learn Zig.** Build a real, non-trivial library that follows Zig idioms and reads like the Zig standard library.

This is **not** a binding to `pico-sdk`. There is no C. Everything - startup code, vector tables, linker layout, register definitions, and drivers - is written in Zig and cross-compiled to bare metal.

> ⚠️ **Status: early / experimental.** Expect breaking changes on every commit until the API stabilizes.

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
  board.zig          Selected-board facade for PCB-level pin assignments
  board/             Board-specific pin definitions
  chip.zig           Selected-chip facade and shared register contract
  chip/              RP2040/RP2350 register definitions and MMIO primitives
  hal/               Portable peripheral operations
  rt/                Private bare-metal runtime: startup, vectors, boot2 /
                     IMAGE_DEF, memory init, and per-board linker scripts
tools/
  boot2_image/       Host build tool: checksums the RP2040 boot2 into a Zig module
  uf2/               Host build tool: packs a firmware ELF into a drag-and-drop .uf2
examples/
  minimal/main.zig      Smallest firmware that builds for the target
  led_on/main.zig       Turns the on-board LED on with raw register writes (no HAL)
  blinky/main.zig       LED blink example
  clock_gpout/main.zig  Puts clk_sys/1000 on GPIO 21, to measure with an instrument
```

By default the runtime brings the chip to its datasheet clock speed - 125 MHz on
the Pico, 150 MHz on the Pico 2 - and starts the 1 microsecond tick domains
before `main`. Firmware that wants the raw reset state instead declares:

```zig
pub const zdk_options: zdk.Options = .{ .startup = .reset_state };
```

As the SDK grows, `src/` will be organized roughly mirroring the hardware:

```
src/
  root.zig           Re-exports the public API
  board/             Board definitions: pins and other PCB-level facts
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

# Put clk_sys / 1000 on GPIO 21 and measure it: 125.000 kHz on the Pico,
# 150.000 kHz on the Pico 2. A reading off by a percent or more means the
# chip is still on its ring oscillator.
zig build clock_gpout

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

`pico-zdk`'s `build.zig` exports a configured `Sdk`: `Sdk.init` validates the
board/arch selection once, resolves the bare-metal target, and owns the library
module, so a firmware can never combine a library module and a target that disagree.
Import the dependency's `build.zig` namespace with `@import("pico_zdk")`:

```zig
const std = @import("std");
const pico_zdk = @import("pico_zdk");

pub fn build(b: *std.Build) void {
    const sdk = pico_zdk.Sdk.init(b, .{
        .board = b.option(pico_zdk.Board, "board", "Target board") orelse .pico,
        .arch = b.option(pico_zdk.Arch, "arch", "RP2350 core: arm or riscv"),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall }),
    });

    const firmware = sdk.addFirmware(.{
        .name = "my_firmware",
        .root_source_file = b.path("src/main.zig"),
    });
    firmware.install();
}
```

`Sdk.init` locates the pico-zdk dependency itself, so it works whatever name you
gave the dependency in `build.zig.zon`. Reuse one `Sdk` for several programs on
one platform; create another `Sdk` for another platform.

`sdk.addFirmware` is the only supported way to build firmware. It returns a
configured `Firmware` containing `.elf` and `.uf2` outputs; `install()` adds
both to the consumer's install step.

## Design principles

I want to to try to implement it the way so it feels like the Zig standard library, and not like a 1:1 port of the C SDK:
**Canonical Zig APIs**, **Comptime-first configuration**, **Datasheet-accurate registers**, **Zero hidden cost**.

## References

- [Raspberry Pi RP2040 datasheet](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf)
- [Raspberry Pi RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
- [Official C/C++ `pico-sdk`](https://github.com/raspberrypi/pico-sdk)
- [MicroZig](https://github.com/ZigEmbeddedGroup/microzig) - the Zig Embedded Group's bare-metal framework; a useful study of MMIO and register-generation patterns in Zig

## Roadmap

### Core SDK → v1.0

- [x] Milestone 0 - Build skeleton
  - [x] Build all three board/architecture targets
  - [x] Provide example discovery and the `addFirmware` build helper
- [x] Milestone 1 - Bootable images and UF2 tooling
  - [x] Add linker layouts, runtime startup code, and boot blocks
  - [x] Ship the UF2 converter and bootable `led_on` example
- [x] Milestone 2 - Chip registers, resets, and GPIO
  - [x] Add typed RP2040/RP2350 registers and reset control
  - [x] Implement SIO
  - [x] Ship the GPIO HAL and real `blinky` example
- [x] Milestone 3 - Clocks and PLLs
  - [x] Configure the external crystal oscillator, phase-locked loops, clock generators, and ticks
  - [x] Ship the `clock_gpout` example
- [ ] Milestone 4 - Timer and sleep
  - [ ] Add microsecond timing, deadlines, and sleep helpers
  - [ ] Make `blinky` run at an exact 1 Hz
- [ ] Milestone 5 - UART, logging, and panic handling
  - [ ] Add UART-backed standard I/O and logging interfaces
  - [ ] Ship `hello_uart` and a diagnostic panic handler
- [ ] Milestone 6 - Tests on hardware (TOH)
  - [ ] Add on-target tests as `hardware_tests` example
  - [ ] Implement host-side build tool for running TOH (runner via pico debug probe)
- [ ] Milestone 7 - Interrupts and alarms
  - [ ] Add ARM and Hazard3 interrupt backends and timer alarms
  - [ ] Ship `blinky_irq` and buffered `uart_echo`
- [ ] Milestone 8 - PWM and ADC
  - [ ] Add PWM slices and ADC sampling support
  - [ ] Ship `pwm_fade` and `adc_temp`
- [ ] Milestone 9 - SPI and I2C
  - [ ] Add blocking SPI and I2C master drivers
  - [ ] Ship `spi_loopback` and `i2c_scan`
- [ ] Milestone 10 - DMA
  - [ ] Add paced, chained, and interrupt-driven transfers
  - [ ] Ship `uart_dma` and DMA TOH coverage
- [ ] Milestone 11 - PIO and comptime assembler
  - [ ] Add PIO state-machine control and instruction encoding
  - [ ] Ship `pio_blink` and `ws2812`
- [ ] Milestone 12 - Bootrom and flash programming
  - [ ] Add bootrom lookup and flash-safe erase/program APIs
  - [ ] Ship `flash_counter` and `zig build flash`
- [ ] Milestone 13 - Multicore and synchronization
  - [ ] Add core launch, spinlocks, FIFO, and flash lockout
  - [ ] Ship `multicore_blink`
- [ ] Milestone 14 - USB CDC device
  - [ ] Add a native USB controller and device stack
  - [ ] Ship `usb_console` and button-free reflashing
- [ ] Milestone 15 - System polish and v1.0
  - [ ] Add watchdog, unique ID, and real-time clock support
  - [ ] Complete documentation

### RP2350 security

- [ ] Milestone 16 - OTP, TRNG, and SHA-256
  - [ ] Add safe OTP access, true randomness, and hardware hashing
  - [ ] Ship `otp_dump` and `trng_rand`
- [ ] Milestone 17 - Signed-image secure boot
  - [ ] Add image signing, key management, and provisioning tools
  - [ ] Verify signed boot and rejection of tampered images
- [ ] Milestone 18 - TrustZone, ACCESSCTRL, and RCP
  - [ ] Split secure/non-secure runtimes and enforce access policy
  - [ ] Ship `trustzone_blink` with fault reporting
- [ ] Milestone 19 - Encrypted boot and A/B partitions
  - [ ] Add encryption, anti-rollback, and A/B update support
  - [ ] Ship automated update, rollback, and release packaging

### Wireless and networking

- [ ] Milestone 20 - CYW43 bring-up
  - [ ] Add W-board definitions and the PIO/DMA gSPI transport
  - [ ] Run `blinky` through the CYW43 GPIO
- [ ] Milestone 21 - Wi-Fi control path
  - [ ] Add scanning, WPA2 joining, and Ethernet frame transport
  - [ ] Ship `wifi_scan` and `wifi_join`
- [ ] Milestone 22 - Native Zig TCP/IP stack
  - [ ] Add ARP, IPv4, ICMP, DHCP, DNS, UDP, and TCP
  - [ ] Ship ping support and `http_hello`

### USB and Bluetooth LE

- [ ] Milestone 23 - USB device classes
  - [ ] Add composite descriptors, HID, MSC, and a shared event loop
  - [ ] Ship keyboard, mass-storage, and composite examples
- [ ] Milestone 24 - USB host
  - [ ] Add host enumeration and HID report handling
  - [ ] Ship the `usb_kbd` example
- [ ] Milestone 25 - a over CYW43
  - [ ] Add firmware upload, bus arbitration, and typed HCI packets
  - [ ] Ship `hci_info` and `ble_beacon`
  - **Fix:** read the milestone title above as “Bluetooth LE over CYW43”.
- [ ] Milestone 26 - BLE peripheral
  - [ ] Add L2CAP, GATT server, pairing, and bonding
  - [ ] Ship the `ble_temp_sensor` service
- [ ] Milestone 27 - BLE central
  - [ ] Add scanning, GATT client support, and Wi-Fi coexistence
  - [ ] Ship `ble_scanner` and `ble_sensor_reader`

### Hardware completion

- [ ] Milestone 28 - Interpolators, DCP, and float acceleration
  - [ ] Add chip-specific compute and GPIO acceleration APIs
  - [ ] Ship `interp_texture` and `mandelbrot_bench`
- [ ] Milestone 29 - HSTX and DVI output
  - [ ] Add HSTX, TMDS encoding, and DMA-fed scanlines
  - [ ] Ship `dvi_color_bars` for Pico 2
- [ ] Milestone 30 - Voltage and power management
  - [ ] Add voltage control, overclocking, sleep, and dormant modes
  - [ ] Ship `overclock` and `dormant_wake`
- [ ] Milestone 31 - Remaining peripherals and tooling polish
  - [ ] Complete slave modes, metadata
  - [ ] Debug I/O
  - [ ] XIP controls

---

## License

All code in this repository is licensed under GNU LESSER GENERAL PUBLIC LICENSE Version 3. As I believe that freedom must be sustained. 
