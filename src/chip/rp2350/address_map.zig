//! RP2350 peripheral block base addresses
//! Datasheet §2.2, "Address Map"

/// RESETS_BASE.
pub const resets_base: u32 = 0x40020000;

/// IO_BANK0_BASE.
pub const io_bank0_base: u32 = 0x40028000;

/// PADS_BANK0_BASE.
pub const pads_bank0_base: u32 = 0x40038000;

/// SIO_BASE.
pub const sio_base: u32 = 0xd0000000;

/// CLOCKS_BASE.
pub const clocks_base: u32 = 0x40010000;

/// XOSC_BASE.
pub const xosc_base: u32 = 0x40048000;

/// PLL_SYS_BASE.
pub const pll_sys_base: u32 = 0x40050000;

/// PLL_USB_BASE.
pub const pll_usb_base: u32 = 0x40058000;

/// TICKS_BASE.
pub const ticks_base: u32 = 0x40108000;

/// USBCTRL_REGS_BASE: the USB controller's register window, above its DPRAM.
pub const usbctrl_regs_base: u32 = 0x50110000;
