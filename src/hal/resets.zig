//! subsystem-reset controller

const chip = @import("../chip.zig");

/// Releases `blocks` from reset via the RESET register's atomic CLEAR alias,
/// then spins until RESET_DONE reports every requested block out of reset.
///
/// Each requested block's required clock must be running before reset is
/// released. Otherwise RESET_DONE may never assert and this function will
/// wait forever.
pub fn releaseAndWait(comptime blocks: []const chip.resets.Block) void {
    var mask: u32 = 0;
    for (blocks) |b| {
        mask |= chip.mask(b);
    }

    chip.resets.registers.reset.clearBits(mask);

    var state: u32 = @bitCast(chip.resets.registers.reset_done.read());
    while (state & mask != mask) {
        state = @bitCast(chip.resets.registers.reset_done.read());
    }
}
