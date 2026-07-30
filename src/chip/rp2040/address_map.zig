//! RP2040 peripheral block base addresses
//! Datasheet §2.2, "Address Map"

/// RESETS_BASE.
pub const resets_base: u32 = 0x4000c000;

/// IO_BANK0_BASE.
pub const io_bank0_base: u32 = 0x40014000;

/// PADS_BANK0_BASE.
pub const pads_bank0_base: u32 = 0x4001c000;

/// SIO_BASE.
pub const sio_base: u32 = 0xd0000000;

/// CLOCKS_BASE.
pub const clocks_base: u32 = 0x40008000;

/// XOSC_BASE.
pub const xosc_base: u32 = 0x40024000;

/// PLL_SYS_BASE.
pub const pll_sys_base: u32 = 0x40028000;

/// PLL_USB_BASE.
pub const pll_usb_base: u32 = 0x4002c000;

/// WATCHDOG_BASE.
pub const watchdog_base: u32 = 0x40058000;

/// USBCTRL_REGS_BASE: the USB controller's register window, above its DPRAM.
pub const usbctrl_regs_base: u32 = 0x50110000;
