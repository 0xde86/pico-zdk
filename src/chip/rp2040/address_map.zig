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
