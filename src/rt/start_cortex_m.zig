//! Cortex-M0+/M33 vector table initialization.
//!
//! Sources: Armv6-M/Armv8-M vector-table architecture and Raspberry Pi's
//! RP2040/RP2350 startup implementation:
//! https://developer.arm.com/documentation/ddi0419/latest/
//! https://developer.arm.com/documentation/ddi0553/latest/
//! https://github.com/raspberrypi/pico-sdk/blob/master/src/rp2_common/pico_crt0/crt0.S

const config = @import("rt_config");
const common = @import("start_common.zig");
const is_rp2040 = config.board == .pico;

extern var __stack_top: u8;

/// System Control Block Vector Table Offset Register (Armv6-M/Armv8-M). The SCB
/// lives at 0xe000_ed00; VTOR is at offset 0x08. Datasheet: RP2040 2.4.5 /
/// RP2350 3.7.6, ARM SCB register map.
const scb_vtor: *volatile u32 = @ptrFromInt(0xe000_ed08);

const Vector = ?*const anyopaque;

// External interrupt slots after the 16 architectural exceptions: RP2040 has 26,
// RP2350 has 52 (datasheet interrupt tables).
const irq_count = if (is_rp2040) 26 else 52;

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
    .memory_management = if (is_rp2040) null else address(defaultHandler),
    .bus_fault = if (is_rp2040) null else address(defaultHandler),
    .usage_fault = if (is_rp2040) null else address(defaultHandler),
    .secure_fault = if (is_rp2040) null else address(defaultHandler),
    .reserved_8 = null,
    .reserved_9 = null,
    .reserved_10 = null,
    .supervisor_call = address(defaultHandler),
    .debug_monitor = if (is_rp2040) null else address(defaultHandler),
    .reserved_13 = null,
    .pendable_service = address(defaultHandler),
    .system_tick = address(defaultHandler),
    .irqs = .{address(defaultHandler)} ** irq_count,
};

/// Reset handler owned by pico-zdk. Applications provide `pub fn main()`.
pub export fn _start() linksection(".reset") callconv(.c) noreturn {
    scb_vtor.* = @intFromPtr(&vector_table);

    common.entry();
}

fn defaultHandler() callconv(.c) noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}
