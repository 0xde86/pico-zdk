//! Selected-chip facade: exposes exactly one chip package, chosen by
//! `config.chip`, and comptime-verifies its contract.

const config = @import("config");

/// The concrete chip facade chosen by build configuration.
const selected = switch (config.chip) {
    .rp2040 => @import("./chip/rp2040.zig"),
    .rp2350 => @import("./chip/rp2350.zig"),
};

/// Reset-controller register package of the selected chip.
pub const resets = selected.resets;

/// User IO bank register package of the selected chip.
pub const io_bank0 = selected.io_bank0;

/// Usable GPIO count of the selected chip/package.
pub const gpio_count = selected.gpio_count;

/// Returns the 32-bit RESETS register mask with `block`'s bit set.
pub inline fn mask(block: resets.Block) u32 {
    return @as(u32, 1) << @intFromEnum(block);
}

comptime {
    const std = @import("std");

    // check that selected chip doesn't drift from the shared facade interface
    _ = selected.resets;
    _ = selected.io_bank0;
    _ = selected.gpio_count;

    std.debug.assert(@bitSizeOf(resets.Reset) == 32);
    std.debug.assert(@offsetOf(resets.Registers, "reset") == 0x00);
    std.debug.assert(@offsetOf(resets.Registers, "wdsel") == 0x04);
    std.debug.assert(@offsetOf(resets.Registers, "reset_done") == 0x08);

    // The HAL builds masks from `Block`, while `Reset` models the same register
    // bits. Verify that both use the same (datasheet-defined) bit positions.
    for (@typeInfo(resets.Block).@"enum".fields) |field| {
        std.debug.assert(@bitOffsetOf(resets.Reset, field.name) == field.value);
    }

    std.debug.assert(@bitSizeOf(io_bank0.GpioStatus) == 32);
    std.debug.assert(@bitSizeOf(io_bank0.GpioCtrl) == 32);
    std.debug.assert(io_bank0.num_gpios >= gpio_count);
    std.debug.assert(@typeInfo(@FieldType(io_bank0.Registers, "io")).array.len == io_bank0.num_gpios);

    for ([_][]const u8{ "spi", "uart", "i2c", "pwm", "sio", "pio0", "pio1", "gpclk", "none" }) |name| {
        std.debug.assert(@hasField(io_bank0.FuncSel, name));
    }

    std.debug.assert(@intFromEnum(io_bank0.FuncSel.sio) == 5);
    std.debug.assert(@intFromEnum(io_bank0.FuncSel.none) == 31);
    std.debug.assert(@as(u32, @bitCast(io_bank0.GpioCtrl{})) == 0x0000_001f);
}
