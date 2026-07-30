//! RP2350 chip facade: the SoC's register blocks under the cross-chip
//! declaration names, plus chip-level facts.

/// Subsystem-reset controller (RESETS).
pub const resets = @import("rp2350/resets.zig");

/// User IO bank (IO_BANK0).
pub const io_bank0 = @import("rp2350/io_bank0.zig");

/// User IO pads (PADS_BANK0).
pub const pads_bank0 = @import("rp2350/pads_bank0.zig");

/// Single-cycle I/O (SIO): processor-facing fast GPIO registers.
pub const sio = @import("rp2350/sio.zig");

/// Crystal oscillator (XOSC).
pub const xosc = @import("rp2350/xosc.zig");

/// Phase-locked loops (PLL_SYS and PLL_USB).
pub const pll = @import("rp2350/pll.zig");

/// Clock generators, muxes, and dividers (CLOCKS).
pub const clocks = @import("rp2350/clocks.zig");

/// USB controller registers (USBCTRL_REGS), modeled down to `SIE_CTRL`.
pub const usb = @import("rp2350/usb.zig");

/// Tick generators (TICKS): six independent dividers off `clk_ref`.
/// The six generators occupy a dedicated register block.
pub const ticks = @import("rp2350/ticks.zig");

/// Datasheet-specified system clock frequency (`SYS_CLK_HZ`).
pub const sys_clk_hz: u32 = 150_000_000;

/// Clock frequency the USB controller and the ADC require (`USB_CLK_HZ`).
pub const usb_clk_hz: u32 = 48_000_000;
