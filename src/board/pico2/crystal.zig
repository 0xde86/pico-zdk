//! Raspberry Pi Pico 2 crystal facts.

/// Frequency of the crystal wired to XOSC, in Hz.
///
/// A property of the PCB, not the chip: the startup plan derives the PLL
/// dividers, the crystal startup delay, and the tick divisor from this number.
pub const xosc_hz: u32 = 12_000_000;
