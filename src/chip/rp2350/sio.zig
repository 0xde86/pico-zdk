//! RP2350 single-cycle I/O (SIO): the processor-local fast GPIO registers.
//!
//! SIO is not on the APB bus and has no atomic alias windows; instead it
//! exposes dedicated SET/CLR/XOR command registers so a single write toggles
//! individual pins race-free. Every GPIO register is a bitmask where bit n
//! selects GPIO n. Only the GPIO portion of the block is modeled here; the
//! FIFO, hardware divider (absent on RP2350), interpolators, and spinlocks
//! will be implemented at later stages.
//!
//! Source: [RP2350 datasheet §3.1, "SIO"](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf).

const mmio = @import("../mmio.zig");
const address_map = @import("./address_map.zig");

/// SIO GPIO register block, GPIO portion only.
///
/// Unlike RP2040, RP2350 **interleaves** each HI word directly after its low
/// counterpart, so every low OUT/OE command register sits one word later than
/// the RP2040 layout (GPIO_OUT_SET at 0x18, GPIO_OE_SET at 0x38). Modeling the
/// HI words is therefore mandatory even though the A-package (Pico 2) uses only
/// the low bank: dropping them would give the low words the wrong byte offsets.
///
/// Every word is a `u32` pin bitmask (bit n = GPIO n); the HAL forms `1 << pin`
/// masks and never reads a status bit through a value type.
pub const Registers = extern struct {
    /// Core number reading the register: 0 on core 0, 1 on core 1.
    cpuid: mmio.ReadOnly(u32),
    /// GPIO_IN: live input level of GPIO 0..31.
    gpio_in: mmio.ReadOnly(u32),
    /// GPIO_HI_IN: live input of GPIO 32..47 plus the USB/QSPI pins.
    gpio_hi_in: mmio.ReadOnly(u32),
    _reserved0: u32,
    /// GPIO_OUT: output latch for GPIO 0..31.
    gpio_out: mmio.ReadWrite(u32),
    /// GPIO_HI_OUT: output latch for the HI bank.
    gpio_hi_out: mmio.ReadWrite(u32),
    /// GPIO_OUT_SET: drive each selected GPIO 0..31 high.
    gpio_out_set: mmio.WriteOnly(u32),
    /// GPIO_HI_OUT_SET.
    gpio_hi_out_set: mmio.WriteOnly(u32),
    /// GPIO_OUT_CLR: drive each selected GPIO 0..31 low.
    gpio_out_clr: mmio.WriteOnly(u32),
    /// GPIO_HI_OUT_CLR.
    gpio_hi_out_clr: mmio.WriteOnly(u32),
    /// GPIO_OUT_XOR: toggle each selected GPIO 0..31.
    gpio_out_xor: mmio.WriteOnly(u32),
    /// GPIO_HI_OUT_XOR.
    gpio_hi_out_xor: mmio.WriteOnly(u32),
    /// GPIO_OE: output-enable latch for GPIO 0..31.
    gpio_oe: mmio.ReadWrite(u32),
    /// GPIO_HI_OE: output-enable latch for the HI bank.
    gpio_hi_oe: mmio.ReadWrite(u32),
    /// GPIO_OE_SET: enable the output driver of each selected GPIO 0..31.
    gpio_oe_set: mmio.WriteOnly(u32),
    /// GPIO_HI_OE_SET.
    gpio_hi_oe_set: mmio.WriteOnly(u32),
    /// GPIO_OE_CLR: disable the output driver of each selected GPIO 0..31.
    gpio_oe_clr: mmio.WriteOnly(u32),
    /// GPIO_HI_OE_CLR.
    gpio_hi_oe_clr: mmio.WriteOnly(u32),
    /// GPIO_OE_XOR: toggle the output driver of each selected GPIO 0..31.
    gpio_oe_xor: mmio.WriteOnly(u32),
    /// GPIO_HI_OE_XOR.
    gpio_hi_oe_xor: mmio.WriteOnly(u32),
};

/// The SIO peripheral at its RP2350 base address. SIO is processor-local, so a
/// read reflects the core that issued it.
pub const registers: *volatile Registers =
    @ptrFromInt(address_map.sio_base);

comptime {
    const std = @import("std");

    // Register offsets per the datasheet. The interleaved HI words push every
    // low OUT/OE command register one slot past its RP2040 offset - this is the
    // layout difference the manual (§9.4) and led_on's 0x018/0x038 encode.
    std.debug.assert(@offsetOf(Registers, "cpuid") == 0x00);
    std.debug.assert(@offsetOf(Registers, "gpio_in") == 0x04);
    std.debug.assert(@offsetOf(Registers, "gpio_hi_in") == 0x08);
    std.debug.assert(@offsetOf(Registers, "gpio_out") == 0x10);
    std.debug.assert(@offsetOf(Registers, "gpio_hi_out") == 0x14);
    std.debug.assert(@offsetOf(Registers, "gpio_out_set") == 0x18);
    std.debug.assert(@offsetOf(Registers, "gpio_hi_out_set") == 0x1c);
    std.debug.assert(@offsetOf(Registers, "gpio_out_clr") == 0x20);
    std.debug.assert(@offsetOf(Registers, "gpio_hi_out_clr") == 0x24);
    std.debug.assert(@offsetOf(Registers, "gpio_out_xor") == 0x28);
    std.debug.assert(@offsetOf(Registers, "gpio_hi_out_xor") == 0x2c);
    std.debug.assert(@offsetOf(Registers, "gpio_oe") == 0x30);
    std.debug.assert(@offsetOf(Registers, "gpio_hi_oe") == 0x34);
    std.debug.assert(@offsetOf(Registers, "gpio_oe_set") == 0x38);
    std.debug.assert(@offsetOf(Registers, "gpio_hi_oe_set") == 0x3c);
    std.debug.assert(@offsetOf(Registers, "gpio_oe_clr") == 0x40);
    std.debug.assert(@offsetOf(Registers, "gpio_hi_oe_clr") == 0x44);
    std.debug.assert(@offsetOf(Registers, "gpio_oe_xor") == 0x48);
    std.debug.assert(@offsetOf(Registers, "gpio_hi_oe_xor") == 0x4c);

    // The modeled GPIO window ends at 0x50; the official block continues with
    // FIFO/interp/spinlock hardware (full size 0x1e8) not used in M2.
    std.debug.assert(@sizeOf(Registers) == 0x50);

    // The on-board LED pin on both supported boards drives bit 25 of the low
    // words (manual §12): 1 << 25.
    std.debug.assert(@as(u32, 1) << 25 == 0x0200_0000);
}
