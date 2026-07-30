//! Portable subsystem-reset controller operations.
//!
//! Hardware behavior follows RP2040 datasheet §2.14, "Subsystem Resets", and
//! RP2350 datasheet §7.5, "Subsystem resets". Chip-specific register layouts
//! and bit positions remain in the selected chip package.

const chip = @import("../chip.zig");

/// Releases `blocks` from reset via the RESET register's atomic CLEAR alias,
/// then spins until RESET_DONE reports every requested block out of reset.
///
/// Each requested block's required clock must be running before reset is
/// released. Otherwise RESET_DONE may never assert and this function will
/// wait forever.
pub fn releaseAndWait(comptime blocks: []const chip.resets.Block) void {
    const mask = comptime blk: {
        var m: u32 = 0;
        for (blocks) |b| m |= chip.mask(b);
        break :blk m;
    };
    releaseMaskAndWait(mask);
}

/// Puts every block selected by `mask` into reset, via the RESET register's
/// atomic SET alias. Blocks outside `mask` are untouched.
///
/// This is the "all but these" counterpart to `releaseAndWait`, for the startup
/// chain's whole-inventory masks. Resetting a block the running program depends
/// on - the QSPI flash interface it executes from, or a PLL feeding a live clock
/// mux - is fatal; `chip.resets.early_reset_mask` is the vetted choice.
pub fn resetMask(mask: u32) void {
    chip.resets.registers.reset.setBits(mask);
}

/// Releases every block selected by `mask` via the RESET register's atomic CLEAR
/// alias, then spins until RESET_DONE reports all of them out of reset.
///
/// Each selected block's required clock must already be running. A block whose
/// functional clock is stopped never asserts RESET_DONE, and this function waits
/// forever - which is why the startup chain splits its releases into a
/// pre-clock and a post-clock half.
pub fn releaseMaskAndWait(mask: u32) void {
    chip.resets.registers.reset.clearBits(mask);

    var state: u32 = @bitCast(chip.resets.registers.reset_done.read());
    while (state & mask != mask) {
        state = @bitCast(chip.resets.registers.reset_done.read());
    }
}
