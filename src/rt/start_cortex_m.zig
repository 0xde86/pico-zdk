//! Cortex-M0+/M33 vector table initialization.
//!
//! Sources: Armv6-M/Armv8-M vector-table architecture and Raspberry Pi's
//! RP2040/RP2350 startup implementation:
//! https://developer.arm.com/documentation/ddi0419/latest/
//! https://developer.arm.com/documentation/ddi0553/latest/
//! https://github.com/raspberrypi/pico-sdk/blob/2.3.0/src/rp2_common/pico_crt0/crt0.S

const config = @import("config");
const common = @import("start_common.zig");

/// Armv6-M (Cortex-M0+) reserves the fault and debug-monitor vectors that
/// Armv8-M (Cortex-M33) defines
const is_v6m = config.core == .cortex_m0plus;

extern var __stack_top: u8;

/// System Control Block Coprocessor Access Control Register (Armv8-M). CPACR
/// controls software access to the RP2350 Cortex-M33's optional coprocessors.
/// Datasheet: RP2350 3.7.6, ARM SCB register map.
const scb_cpacr: *volatile u32 = @ptrFromInt(0xe000_ed88);

// CP10 and CP11 jointly control the single-precision floating-point extension.
// Both two-bit fields must be 0b11 for privileged and unprivileged access.
const cpacr_fpu_full_access: u32 = (0b11 << 20) | (0b11 << 22);

const Vector = ?*const anyopaque;

// External interrupt slots after the 16 architectural exceptions: RP2040 has 26,
// RP2350 has 52 (datasheet interrupt tables)
const irq_count = if (config.chip == .rp2040) 26 else 52;

const VectorTable = extern struct {
    initial_stack_pointer: Vector,
    reset: Vector,
    nmi: Vector,
    hard_fault: Vector,
    memory_management: Vector,
    bus_fault: Vector,
    usage_fault: Vector,
    secure_fault: Vector,
    reserved_8: Vector,
    reserved_9: Vector,
    reserved_10: Vector,
    supervisor_call: Vector,
    debug_monitor: Vector,
    reserved_13: Vector,
    pendable_service: Vector,
    system_tick: Vector,
    irqs: [irq_count]Vector,
};

fn address(comptime declaration: anytype) Vector {
    return @ptrCast(&declaration);
}

/// Initial Cortex-M exception and interrupt vector table.
pub export const vector_table linksection(".vectors") = VectorTable{
    .initial_stack_pointer = @ptrCast(&__stack_top),
    .reset = address(_start),
    .nmi = address(defaultHandler),
    .hard_fault = address(defaultHandler),
    .memory_management = if (is_v6m) null else address(defaultHandler),
    .bus_fault = if (is_v6m) null else address(defaultHandler),
    .usage_fault = if (is_v6m) null else address(defaultHandler),
    .secure_fault = if (is_v6m) null else address(defaultHandler),
    .reserved_8 = null,
    .reserved_9 = null,
    .reserved_10 = null,
    .supervisor_call = address(defaultHandler),
    .debug_monitor = if (is_v6m) null else address(defaultHandler),
    .reserved_13 = null,
    .pendable_service = address(defaultHandler),
    .system_tick = address(defaultHandler),
    .irqs = .{address(defaultHandler)} ** irq_count,
};

/// Reset handler owned by pico-zdk. Applications provide `pub fn main()`.
///
/// This prelude is naked because the core-1 check must happen before generated
/// code can touch the stack. A stray core 1 may have been given core 0's vector
/// table and therefore its stack pointer; it must return to the ROM without
/// pushing even one word there.
pub export fn _start() linksection(".reset") callconv(.naked) noreturn {
    asm volatile (
        \\ ldr  r0, =0xd0000000
        \\ ldr  r0, [r0]
        \\ cmp  r0, #0
        \\ bne  _entry_point
        \\ ldr  r0, =vector_table
        \\ ldr  r1, =0xe000ed08
        \\ str  r0, [r1]
        \\ b    _runtime_start
    );
}

/// ELF debugger entry point and core-1 return path.
///
/// A debugger jumps here after programming flash, and `_start` redirects core 1
/// here before touching its possibly shared stack. Re-entering the ROM repeats
/// the normal flash boot and reaches `_start` through the firmware vector table.
/// Armv8-M clears `MSPLIM` before any stack access because the previous context
/// can leave a stack limit that is invalid for the ROM's restored stack.
pub export fn _entry_point() linksection(".reset") callconv(.naked) noreturn {
    if (is_v6m) {
        asm volatile (
            \\ movs r0, #0
            \\ b    _enter_vector_table
        );
    } else {
        asm volatile (
            \\ movs r0, #0
            \\ msr  msplim, r0
            \\ b    _enter_vector_table
        );
    }
}

/// Enters the Arm vector table whose address is in `r0`.
///
/// Address zero is the boot ROM vector table on RP2040 and RP2350. This routine
/// deliberately has no Zig pointer conversion: zero is a valid hardware
/// address here, despite being the language-level null pointer value.
pub export fn _enter_vector_table() linksection(".reset") callconv(.naked) noreturn {
    asm volatile (
        \\ ldr   r1, =0xe000ed08
        \\ str   r0, [r1]
        \\ ldmia r0!, {r1, r2}
        \\ msr   msp, r1
        \\ bx    r2
    );
}

/// Enters initialized Zig code on core 0.
pub export fn _runtime_start() callconv(.c) noreturn {
    if (!is_v6m) enableFpu();
    common.entry();
}

/// Enables the Cortex-M33 single-precision FPU before application code runs.
/// DSB completes the CPACR write and ISB makes subsequent instructions observe
/// the updated coprocessor access permissions, as required by Armv8-M.
inline fn enableFpu() void {
    scb_cpacr.* |= cpacr_fpu_full_access;
    asm volatile (
        \\ dsb
        \\ isb
        ::: .{ .memory = true });
}

fn defaultHandler() callconv(.c) noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}
