//! Selected-chip facade: exposes exactly one chip package, chosen by
//! `config.chip`, and comptime-verifies its contract.

const config = @import("config");

/// Reset-controller register package of the selected chip.
pub const resets = if (config.chip == .rp2040)
    @import("./chip/rp2040/resets.zig")
else
    @import("./chip/rp2350/resets.zig");

/// Returns the 32-bit RESETS register mask with `block`'s bit set.
pub fn mask(block: resets.Block) u32 {
    return @as(u32, 1) << @intFromEnum(block);
}

comptime {
    const std = @import("std");

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
