//! Selected-board facade: re-exposes the board module matching the
//! configured target.

const config = @import("config");

/// Pin assignments provided by the configured board.
const pins = switch (config.board) {
    .pico => @import("board/pico/pins.zig"),
    .pico2 => @import("board/pico2/pins.zig"),
};

/// Named GPIO connections provided by the configured board.
pub const Pin = pins.Pin;
