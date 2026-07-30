//! RP2350 user IO pads (PADS_BANK0): the electrical behavior of each package pin.
//!
//! This block decides how the pin's transistor-level interface behaves -
//! input buffer, output driver, drive strength, edge speed, and weak pulls.
//!
//! Source: [RP2350 datasheet §9.11, "PADS_BANK0 registers"](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// Nominal output drive strength (datasheet field `DRIVE`).
/// A rating of the pad's current capability.
pub const Drive = enum(u2) {
    ma_2 = 0,
    ma_4 = 1,
    ma_8 = 2,
    ma_12 = 3,
};

/// Bank-wide supply voltage mode (datasheet field `VOLTAGE_SELECT`).
pub const Voltage = enum(u1) {
    /// 3.3 V mode; requires DVDD of at least 2.5 V. Reset value.
    v3_3 = 0,
    /// 1.8 V mode; requires DVDD of at most 1.8 V.
    v1_8 = 1,
};

/// VOLTAGE_SELECT: supply voltage mode for every pad in the bank.
pub const VoltageSelect = packed struct(u32) {
    voltage: Voltage = .v3_3,
    _reserved0: u31 = 0,
};

/// GPIOn: the electrical controls for one pad. Every field defaults to its
/// reset value, so `Pad{}` is the complete power-on word. A partial initializer
/// still constructs a complete word using these defaults; callers that must
/// preserve live fields use an APB masked update.
pub const Pad = packed struct(u32) {
    /// `SLEWFAST`: false selects limited edge rates, true fast edges.
    slew_fast: bool = false,
    /// `SCHMITT`: input hysteresis, so a slow or noisy digital input is less
    /// likely to chatter.
    schmitt: bool = true,
    /// `PDE`: weak pull-down enable. See the E9 erratum note on this module
    /// before relying on it to hold a floating Bank 0 input low.
    pull_down: bool = true,
    /// `PUE`: weak pull-up enable. With both pulls enabled the pad behaves as
    /// a bus keeper.
    pull_up: bool = false,
    /// `DRIVE`: nominal output drive strength.
    drive: Drive = .ma_4,
    /// `IE`: digital input-buffer enable. Powers up *disabled*, so a pin cannot
    /// be read until the HAL enables it.
    input_enable: bool = false,
    /// `OD`: output disable. Overrides the output enable coming from SIO or
    /// any peripheral, so it is a high-priority gate.
    output_disable: bool = false,
    /// `ISO`: pad isolation. Every pad powers up isolated and conducts nothing
    /// until this is cleared, which must happen *after* the pad and the mux
    /// are configured.
    isolate: bool = true,
    _reserved0: u23 = 0,
};

/// Pad register slots defined by the PADS_BANK0 block, one per GPIO. The
/// RP2350 die carries 48 slots (B-package superset); the A-package (Pico 2)
/// only bonds the first 30. The usable pin count is the facade's `gpio_count`.
pub const num_pads = 48;

/// PADS_BANK0 register block: the bank-wide voltage mode, then one word per
/// pad. Every register is APB read-write so the HAL can masked-update one
/// field while preserving the rest of the pad's configuration.
pub const Registers = extern struct {
    voltage_select: mmio.ApbReadWrite(VoltageSelect),
    gpio: [num_pads]mmio.ApbReadWrite(Pad),
};

/// The PADS_BANK0 peripheral at its RP2350 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.pads_bank0_base);

comptime {
    const std = @import("std");

    // Field bit positions per the datasheet register definition.
    std.debug.assert(@bitOffsetOf(Pad, "slew_fast") == 0);
    std.debug.assert(@bitOffsetOf(Pad, "schmitt") == 1);
    std.debug.assert(@bitOffsetOf(Pad, "pull_down") == 2);
    std.debug.assert(@bitOffsetOf(Pad, "pull_up") == 3);
    std.debug.assert(@bitOffsetOf(Pad, "drive") == 4);
    std.debug.assert(@bitOffsetOf(Pad, "input_enable") == 6);
    std.debug.assert(@bitOffsetOf(Pad, "output_disable") == 7);
    std.debug.assert(@bitOffsetOf(Pad, "isolate") == 8);
    std.debug.assert(@bitOffsetOf(VoltageSelect, "voltage") == 0);

    // The pad powers up isolated with its input buffer disabled
    std.debug.assert(@as(u32, @bitCast(Pad{})) == 0x0000_0116);
    std.debug.assert(@as(u32, @bitCast(VoltageSelect{})) == 0x0000_0000);

    // Drive encodings.
    std.debug.assert(@intFromEnum(Drive.ma_2) == 0);
    std.debug.assert(@intFromEnum(Drive.ma_4) == 1);
    std.debug.assert(@intFromEnum(Drive.ma_8) == 2);
    std.debug.assert(@intFromEnum(Drive.ma_12) == 3);

    // Block layout: VOLTAGE_SELECT at +0x00, pads from +0x04, 4 bytes each.
    std.debug.assert(@offsetOf(Registers, "voltage_select") == 0x00);
    std.debug.assert(@offsetOf(Registers, "gpio") == 0x04);
    std.debug.assert(@sizeOf(Registers) == 0xc4);
    // The on-board LED pin on both supported boards, as worked through in the
    // manual: 0x04 + 25*4.
    std.debug.assert(@offsetOf(Registers, "gpio") + 25 * 4 == 0x68);
}
