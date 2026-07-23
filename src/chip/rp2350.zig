//! RP2350 chip facade: the SoC's register blocks under the cross-chip
//! declaration names, plus chip-level facts.

/// Subsystem-reset controller (RESETS).
pub const resets = @import("rp2350/resets.zig");

/// User IO bank (IO_BANK0)
pub const io_bank0 = @import("rp2350/io_bank0.zig");

/// User IO pads (PADS_BANK0)
pub const pads_bank0 = @import("rp2350/pads_bank0.zig");

/// Usable GPIO count for this chip. Source: RP2350 `platform_defs.h`
/// `NUM_BANK0_GPIOS`. 30 on the A-package (QFN-60, used by Pico 2); the
/// B-package (QFN-80) exposes 48 — a B-package board would make this
/// package-parameterized, not modeled until I have such board :)
pub const gpio_count = 30;
