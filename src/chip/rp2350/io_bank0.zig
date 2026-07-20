//! RP2350 user IO bank (IO_BANK0): per-pin GPIO status and function-select mux.
//!
//! Source: [RP2350 datasheet §9.11, "IO_BANK0 registers"](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// GPIOx_STATUS: read-only view of a pin's post-override output, output-enable,
/// input, and interrupt-to-processor signals. RP2350 exposes fewer status bits
/// than RP2040 (no pre-override "from peri"/"from pad" mirrors except INFROMPAD).
pub const GpioStatus = packed struct(u32) {
    _reserved0: u9 = 0,
    /// Output signal to the pad, after the OUTOVER override.
    out_to_pad: u1,
    _reserved1: u3 = 0,
    /// Output enable to the pad, after the OEOVER override.
    oe_to_pad: u1,
    _reserved2: u3 = 0,
    /// Input signal from the pad, before filtering and the INOVER override.
    in_from_pad: u1,
    _reserved3: u8 = 0,
    /// Interrupt to the processors, after the IRQOVER override.
    irq_to_proc: u1,
    _reserved4: u5 = 0,
};

/// GPIOx_CTRL: pin function select plus per-signal overrides. The override
/// fields sit at different bit positions than on RP2040 (OUTOVER/OEOVER moved
/// up to bits 12..15).
pub const GpioCtrl = packed struct(u32) {
    /// Function select (0..31): peripheral routed to the pin. The encoding is
    /// chip-specific and owned by the HAL's `Function` mapping.
    funcsel: u5,
    _reserved0: u7 = 0,
    /// Output signal override (0 normal, 1 invert, 2 drive low, 3 drive high).
    out_over: u2,
    /// Output-enable override (0 from peripheral, 1 invert, 2 disable, 3 enable).
    oe_over: u2,
    /// Input override (0 normal, 1 invert, 2 drive low, 3 drive high).
    in_over: u2,
    _reserved1: u10 = 0,
    /// Interrupt override (0 normal, 1 invert, 2 drive low, 3 drive high).
    irq_over: u2,
    _reserved2: u2 = 0,
};

/// One GPIO's register pair: STATUS (read-only) then CTRL (8 bytes), as laid
/// out per pin in the IO_BANK0 array. CTRL is APB read-write so the HAL can
/// masked-update FUNCSEL while preserving the overrides.
pub const Gpio = extern struct {
    status: mmio.ReadOnly(GpioStatus),
    ctrl: mmio.ApbReadWrite(GpioCtrl),
};

/// GPIO register slots defined by the IO_BANK0 block (register-map size). The
/// RP2350 die carries 48 slots (B-package superset); the A-package (Pico 2)
/// only bonds the first 30. The usable pin count is the facade's `gpio_count`.
const num_gpios = 48;

/// IO_BANK0 register block
pub const Registers = extern struct {
    io: [num_gpios]Gpio,
};

/// The IO_BANK0 peripheral at its RP2350 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.io_bank0_base);

comptime {
    const std = @import("std");

    // Field bit positions per the datasheet register definitions.
    std.debug.assert(@bitOffsetOf(GpioStatus, "out_to_pad") == 9);
    std.debug.assert(@bitOffsetOf(GpioStatus, "oe_to_pad") == 13);
    std.debug.assert(@bitOffsetOf(GpioStatus, "in_from_pad") == 17);
    std.debug.assert(@bitOffsetOf(GpioStatus, "irq_to_proc") == 26);

    std.debug.assert(@bitOffsetOf(GpioCtrl, "funcsel") == 0);
    std.debug.assert(@bitOffsetOf(GpioCtrl, "out_over") == 12);
    std.debug.assert(@bitOffsetOf(GpioCtrl, "oe_over") == 14);
    std.debug.assert(@bitOffsetOf(GpioCtrl, "in_over") == 16);
    std.debug.assert(@bitOffsetOf(GpioCtrl, "irq_over") == 28);

    // Block layout: STATUS at +0x00, CTRL at +0x04, 8 bytes per pin.
    std.debug.assert(@offsetOf(Gpio, "status") == 0x00);
    std.debug.assert(@offsetOf(Gpio, "ctrl") == 0x04);
    std.debug.assert(@sizeOf(Gpio) == 8);
    std.debug.assert(@sizeOf(Registers) == num_gpios * 8);
}
