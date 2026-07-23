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

/// User IO pad register package of the selected chip.
pub const pads_bank0 = selected.pads_bank0;

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
    _ = selected.pads_bank0;
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

    std.debug.assert(@bitSizeOf(pads_bank0.Pad) == 32);
    std.debug.assert(pads_bank0.num_pads >= gpio_count);
    std.debug.assert(@typeInfo(@FieldType(pads_bank0.Registers, "gpio")).array.len == pads_bank0.num_pads);

    // Both blocks are indexed by the same pin number, so their slot counts
    // must agree - otherwise a pin valid for the mux could have no pad.
    std.debug.assert(pads_bank0.num_pads == io_bank0.num_gpios);

    // Pad fields the HAL drives on both chips. `isolate` is deliberately
    // absent from this list: it exists only on RP2350, and the HAL branches on
    // the chip rather than writing a reserved bit on RP2040.
    for ([_][]const u8{ "slew_fast", "schmitt", "pull_down", "pull_up", "drive", "input_enable", "output_disable" }) |name| {
        std.debug.assert(@hasField(pads_bank0.Pad, name));
    }

    // Drive strength is a shared four-value encoding, unlike the pad reset
    // word, which differs per chip and is asserted in each register file.
    for ([_][]const u8{ "ma_2", "ma_4", "ma_8", "ma_12" }) |name| {
        std.debug.assert(@hasField(pads_bank0.Drive, name));
    }
    std.debug.assert(@intFromEnum(pads_bank0.Drive.ma_4) == 1);
}
