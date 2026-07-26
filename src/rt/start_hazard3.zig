//! RP2350 Hazard3 reset and trap startup.
//!
//! Sources: RP2350 datasheet section 3.8, the RISC-V privileged architecture,
//! RISC-V ELF psABI, and Raspberry Pi's Hazard3 startup implementation:
//! https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
//! https://github.com/riscv/riscv-isa-manual/releases
//! https://github.com/riscv-non-isa/riscv-elf-psabi-doc
//! https://github.com/raspberrypi/pico-sdk/blob/2.3.0/src/rp2_common/pico_crt0/crt0_riscv.S

const common = @import("start_common.zig");

/// Direct-mode machine trap vector installed in `mtvec` by `_start`.
///
/// `_default_trap` is co-located in `.vectors` (below) so this forwarding jump
/// stays within RISC-V `JAL`'s ~±1 MiB reach regardless of how large the
/// application's `.text` grows.
pub export fn _trap_vector() align(4) linksection(".vectors") callconv(.naked) noreturn {
    // mtvec points here; forward every trap to the parked handler below.
    asm volatile ("j _default_trap");
}

/// Establishes the RISC-V ABI registers and enters the Zig runtime initializer.
pub export fn _start() linksection(".reset") callconv(.naked) noreturn {
    asm volatile (
    // Core-1 guard: only core 0 may run the runtime initialization.
        \\ csrr a0, mhartid       // hart id: 0 on core 0, 1 on core 1. The RISC-V
        \\                        // counterpart of SIO CPUID, but architecturally
        \\                        // specified rather than a chip register
        \\ bnez a0, _entry_point  // back to the ROM's launch-wait loop
        \\ .option push
        \\ .option norelax           // keep the next `la` PC-relative: linker relaxation would
        \\                           // rewrite it as gp-relative, but gp isn't set up yet
        \\ la gp, __global_pointer$  // gp (x3) = global pointer, for gp-relative access to small globals
        \\ .option pop               // re-enable relaxation for everything after
        \\ la sp, __stack_top        // sp (x2) = top of stack (symbol from the linker script)
        \\ la t0, _trap_vector       // t0 = address the core jumps to on any trap/interrupt
        \\ csrw mtvec, t0            // mtvec packs a base address + a 2-bit MODE in its low bits;
        \\                           // t0 is 4-byte aligned so MODE = 0 (Direct): all traps jump to _trap_vector
        \\ tail _runtime_start       // tail-call the runtime (mem init + call main); never returns
    );
}

/// ELF debugger entry point and core-1 return path.
///
/// RP2350 exposes a dedicated RISC-V ROM entry instruction at `0x0000_7dfc`.
/// Address zero contains the Arm vector table and is not executable Hazard3
/// reset code. Datasheet: RP2350 Table 454, "Bootrom contents at fixed (well
/// known) addresses for RISC-V code".
pub export fn _entry_point() align(4) linksection(".reset") callconv(.naked) noreturn {
    asm volatile (
        \\ li t0, 0x7dfc
        \\ jr t0
    );
}

/// Enters the shared runtime: reset-time memory init and the application entry.
pub export fn _runtime_start() callconv(.c) noreturn {
    common.entry();
}

/// Default trap handler: parks the core in a low-power wait-for-interrupt loop.
///
/// Placed in `.vectors` so it sits immediately next to `_trap_vector`, keeping
/// that section's forwarding `j` in `JAL` range no matter the firmware size.
pub export fn _default_trap() align(4) linksection(".vectors") callconv(.naked) noreturn {
    asm volatile (
        \\ wfi              // wait for interrupt: halt the core in a low-power state
        \\ j _default_trap  // loop back if wfi wakes spuriously (e.g. debugger)
    );
}
