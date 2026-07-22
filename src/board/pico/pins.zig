//! Raspberry Pi Pico PCB pin assignments.

/// Named GPIO pins wired to on-board Pico components.
pub const Pin = enum(u6) {
    /// Active-high on-board LED, connected directly to GPIO 25.
    led = 25,
};
