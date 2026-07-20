//! RP2350 subsystem-reset controller (RESETS).
//!
//! Source: [RP2350 datasheet §7.5, "Subsystem resets"](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf#section_subsystem_resets).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// Bit position of each resettable subsystem within the RESETS registers.
///
/// Positions are chip-specific (relative to RP2040 this adds hstx, pio2,
/// sha256, timer0/timer1, and trng, and drops rtc); the member names shared
/// with RP2040 are part of the cross-chip contract probed in `chip.zig`.
pub const Block = enum(u5) {
    adc = 0,
    busctrl = 1,
    dma = 2,
    hstx = 3,
    i2c0 = 4,
    i2c1 = 5,
    io_bank0 = 6,
    io_qspi = 7,
    jtag = 8,
    pads_bank0 = 9,
    pads_qspi = 10,
    pio0 = 11,
    pio1 = 12,
    pio2 = 13,
    pll_sys = 14,
    pll_usb = 15,
    pwm = 16,
    sha256 = 17,
    spi0 = 18,
    spi1 = 19,
    syscfg = 20,
    sysinfo = 21,
    tbman = 22,
    timer0 = 23,
    timer1 = 24,
    trng = 25,
    uart0 = 26,
    uart1 = 27,
    usbctrl = 28,
};

/// Register value layout shared by RESET, WDSEL, and RESET_DONE: one bit
/// per subsystem, assigned as in `Block` (RP2350 datasheet §7.5).
pub const Reset = packed struct(u32) {
    adc: u1,
    busctrl: u1,
    dma: u1,
    hstx: u1,
    i2c0: u1,
    i2c1: u1,
    io_bank0: u1,
    io_qspi: u1,
    jtag: u1,
    pads_bank0: u1,
    pads_qspi: u1,
    pio0: u1,
    pio1: u1,
    pio2: u1,
    pll_sys: u1,
    pll_usb: u1,
    pwm: u1,
    sha256: u1,
    spi0: u1,
    spi1: u1,
    syscfg: u1,
    sysinfo: u1,
    tbman: u1,
    timer0: u1,
    timer1: u1,
    trng: u1,
    uart0: u1,
    uart1: u1,
    usbctrl: u1,
    _reserved0: u3 = 0,
};

/// RESETS register block; member offsets are pinned by the comptime
/// asserts in `chip.zig`.
pub const Registers = extern struct {
    reset: mmio.ApbReadWrite(Reset),
    wdsel: mmio.ApbReadWrite(Reset),
    reset_done: mmio.ReadOnly(Reset),
};

/// The RESETS peripheral at its RP2350 base address.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.resets_base);
