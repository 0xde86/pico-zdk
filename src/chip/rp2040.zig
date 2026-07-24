//! RP2040 chip facade: the SoC's register blocks under the cross-chip
//! declaration names, plus chip-level facts.

/// Subsystem-reset controller (RESETS).
pub const resets = @import("rp2040/resets.zig");

/// User IO bank (IO_BANK0).
pub const io_bank0 = @import("rp2040/io_bank0.zig");

/// User IO pads (PADS_BANK0).
pub const pads_bank0 = @import("rp2040/pads_bank0.zig");

/// Single-cycle I/O (SIO): processor-facing fast GPIO registers.
pub const sio = @import("rp2040/sio.zig");
