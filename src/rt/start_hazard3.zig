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
    asm volatile ("j _default_trap"); // Forward every trap to a nearby park loop because no recoverable trap API exists yet.
}

/// Establishes the RISC-V ABI registers and enters the Zig runtime initializer.
pub export fn _start() linksection(".reset") callconv(.naked) noreturn {
    asm volatile (
        \\ csrr a0, mhartid          // Read the architectural hart ID before shared state so only core 0 initializes it.
        \\ bnez a0, _entry_point     // Return core 1 to the ROM launch-wait path instead of sharing core 0's stack.
        \\ .option push              // Save the caller's assembler options so the startup-only relaxation rule is local.
        \\ .option norelax           // Keep the following address load PC-relative because gp is not initialized yet.
        \\ la gp, __global_pointer$  // Establish the psABI global pointer before generated Zig may address small data.
        \\ .option pop               // Restore relaxation now that gp-relative linker rewrites are safe.
        \\ la sp, __stack_top        // Install the linker-provided core-0 stack before calling generated Zig code.
        \\ la t0, _trap_vector       // Materialize the aligned trap-vector address required for direct mtvec mode.
        \\ csrw mtvec, t0            // Route early traps to a known park handler instead of an unknown reset value.
        \\ tail _runtime_start       // Avoid an unused return frame while transferring permanently into the runtime.
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
        \\ li t0, 0x7dfc // Materialize the RP2350's documented Hazard3 ROM entry; address zero is an Arm vector table.
        \\ jr t0         // Re-enter ROM so debugger starts and stray core 1 both follow the supported boot/park logic.
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
        \\ wfi             // Stop consuming execution bandwidth because no handler can safely recover this trap yet.
        \\ j _default_trap // Park again after a debugger or spurious event wakes WFI without resolving the trap.
    );
}
