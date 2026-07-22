//! RP2040 chip facade: the SoC's register blocks under the cross-chip
//! declaration names, plus chip-level facts.

/// Subsystem-reset controller (RESETS).
pub const resets = @import("rp2040/resets.zig");

/// User IO bank (IO_BANK0)
pub const io_bank0 = @import("rp2040/io_bank0.zig");

/// Usable GPIO count for this chip. Source: RP2040 `platform_defs.h`
/// `NUM_BANK0_GPIOS` (30) — GPIO0..29 on every RP2040 package.
pub const gpio_count = 30;
