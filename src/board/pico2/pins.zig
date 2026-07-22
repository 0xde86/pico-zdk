//! Raspberry Pi Pico 2 PCB pin assignments.

/// Named GPIO pins wired to on-board Pico 2 components.
pub const Pin = enum(u6) {
    /// Active-high on-board LED, connected directly to GPIO 25.
    led = 25,
};
