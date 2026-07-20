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

/// Usable GPIO count of the selected chip/package.
pub const gpio_count = selected.gpio_count;

/// Returns the 32-bit RESETS register mask with `block`'s bit set.
pub fn mask(block: resets.Block) u32 {
    return @as(u32, 1) << @intFromEnum(block);
}

comptime {
    const std = @import("std");

    // check that selected chip doesn't drift from the shared facade interface
    _ = selected.resets;
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
}
