//! RP2040 subsystem-reset controller (RESETS).
//!
//! Source: [RP2040 datasheet §2.14, "Subsystem Resets"](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf#section_resets).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// Bit position of each resettable subsystem within the RESETS registers.
///
/// Positions are chip-specific; the member names shared with RP2350 are
/// part of the cross-chip contract probed in `chip.zig`.
pub const Block = enum(u5) {
    adc = 0,
    busctrl = 1,
    dma = 2,
    i2c0 = 3,
    i2c1 = 4,
    io_bank0 = 5,
    io_qspi = 6,
    jtag = 7,
    pads_bank0 = 8,
    pads_qspi = 9,
    pio0 = 10,
    pio1 = 11,
    pll_sys = 12,
    pll_usb = 13,
    pwm = 14,
    rtc = 15,
    spi0 = 16,
    spi1 = 17,
    syscfg = 18,
    sysinfo = 19,
    tbman = 20,
    timer = 21,
    uart0 = 22,
    uart1 = 23,
    usbctrl = 24,
};

/// Register value layout shared by RESET, WDSEL, and RESET_DONE: one bit
/// per subsystem, assigned as in `Block` (RP2040 datasheet §2.14.3).
pub const Reset = packed struct(u32) {
    adc: u1,
    busctrl: u1,
    dma: u1,
    i2c0: u1,
    i2c1: u1,
    io_bank0: u1,
    io_qspi: u1,
    jtag: u1,
    pads_bank0: u1,
    pads_qspi: u1,
    pio0: u1,
    pio1: u1,
    pll_sys: u1,
    pll_usb: u1,
    pwm: u1,
    rtc: u1,
    spi0: u1,
    spi1: u1,
    syscfg: u1,
    sysinfo: u1,
    tbman: u1,
    timer: u1,
    uart0: u1,
    uart1: u1,
    usbctrl: u1,
    _reserved0: u7 = 0,
};

/// RESETS register block; member offsets are pinned by the comptime
/// asserts in `chip.zig`.
pub const Registers = extern struct {
    reset: mmio.ApbReadWrite(Reset),
    wdsel: mmio.ApbReadWrite(Reset),
    reset_done: mmio.ReadOnly(Reset),
};

/// The RESETS peripheral at its RP2040 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.resets_base);
