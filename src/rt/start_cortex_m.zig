//! Cortex-M0+/M33 vector table initialization.
//!
//! Sources: Armv6-M/Armv8-M vector-table architecture and Raspberry Pi's
//! RP2040/RP2350 startup implementation:
//! https://developer.arm.com/documentation/ddi0419/latest/
//! https://developer.arm.com/documentation/ddi0553/latest/
//! https://github.com/raspberrypi/pico-sdk/blob/master/src/rp2_common/pico_crt0/crt0.S

const config = @import("config");
const common = @import("start_common.zig");

/// Armv6-M (Cortex-M0+) reserves the fault and debug-monitor vectors that
/// Armv8-M (Cortex-M33) defines
const is_v6m = config.core == .cortex_m0plus;

extern var __stack_top: u8;

/// System Control Block Vector Table Offset Register (Armv6-M/Armv8-M). The SCB
/// lives at 0xe000_ed00; VTOR is at offset 0x08. Datasheet: RP2040 2.4.5 /
/// RP2350 3.7.6, ARM SCB register map.
const scb_vtor: *volatile u32 = @ptrFromInt(0xe000_ed08);

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
pub export fn _start() linksection(".reset") callconv(.c) noreturn {
    scb_vtor.* = @intFromPtr(&vector_table);

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
