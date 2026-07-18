//! `led_on` - the "hello world" of first milestone: turn the on-board LED on and then stop.
//!
//! Register addresses, reset-bit positions, and the SIO layout differ between
//! the two chips, so every chip-specific constant below is chosen at comptime
//! from the build target. Sources:
//!   - RP2040 datasheet (address map, RESETS, IO_BANK0, PADS_BANK0, SIO):
//!     https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
//!   - RP2350 datasheet (same blocks; note the SIO GPIO register reshuffle and
//!     the new per-pad isolation latch):
//!     https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
//!   - pico-sdk hardware_regs headers (addressmap, resets, io_bank0,
//!     pads_bank0, sio) for the exact offsets and bit positions.

const std = @import("std");
const builtin = @import("builtin");

const is_rp2040 = builtin.cpu.arch == .thumb and
    builtin.cpu.model == &std.Target.arm.cpu.cortex_m0plus;

// --- Peripheral base addresses (RP2040 vs RP2350) --------------------------
// The GPIO-related blocks live at different APB addresses on the two chips.
// SIO is a single-cycle, core-local block and sits at the same address on both.

/// RESETS block: releases peripherals from their power-on reset.
const resets_base: u32 = if (is_rp2040) 0x4000_c000 else 0x4002_0000;
/// IO_BANK0 block: per-pin function select (the pin mux).
const io_bank0_base: u32 = if (is_rp2040) 0x4001_4000 else 0x4002_8000;
/// PADS_BANK0 block: per-pin electrical pad control (drive, pulls, isolation).
const pads_bank0_base: u32 = if (is_rp2040) 0x4001_c000 else 0x4003_8000;
/// SIO block: single-cycle GPIO; identical address on both chips.
const sio_base: u32 = 0xd000_0000;

// --- Atomic register-access aliases ----------------------------------------
// Each APB peripheral's 4 KiB window is mirrored three more times just above
// it. A write through an alias performs a read-modify-write in hardware, so an
// individual bit can be flipped without a separate read and without disturbing
// the other bits of a shared register (RP2040 datasheet 2.1.2).
const atomic_xor: u32 = 0x1000; // write here: reg ^= value
const atomic_set: u32 = 0x2000; // write here: reg |= value
const atomic_clr: u32 = 0x3000; // write here: reg &= ~value

// --- RESETS register offsets and bits --------------------------------------
/// RESET register: a 1 bit holds the matching peripheral in reset.
const resets_reset: u32 = 0x0;
/// RESET_DONE register: a 1 bit means that peripheral has finished leaving reset.
const resets_reset_done: u32 = 0x8;

/// RESET bit for IO_BANK0 (the bit position differs between the two chips).
const reset_io_bank0: u32 = if (is_rp2040) 1 << 5 else 1 << 6;
/// RESET bit for PADS_BANK0.
const reset_pads_bank0: u32 = if (is_rp2040) 1 << 8 else 1 << 9;

// --- The on-board LED pin ---------------------------------------------------
/// Both boards wire the user LED to GPIO 25.
const led_pin = 25;
/// Mask selecting GPIO 25 within the 32-bit SIO GPIO registers.
const led_mask: u32 = 1 << led_pin;

/// IO_BANK0 stores an 8-byte record per GPIO (STATUS at +0x0, CTRL at +0x4),
/// so GPIO 25's CTRL register is at 25*8 + 4 = 0xcc.
const gpio25_ctrl: u32 = led_pin * 8 + 4;
/// Function number that connects a pad to the SIO GPIO registers (F5 on both
/// chips). Written into CTRL.FUNCSEL (bits 4:0); writing it as the whole
/// register leaves every override field at 0 (normal)
const funcsel_sio: u32 = 5;

/// PADS_BANK0 begins with VOLTAGE_SELECT at +0x0, then one 4-byte register per
/// GPIO, so GPIO 25's pad register is at 0x04 + 25*4 = 0x68.
const gpio25_pad: u32 = 0x04 + led_pin * 4;
/// PADS.OD (output disable, bit 7): must be 0 for the pad to drive the pin.
const pad_output_disable: u32 = 1 << 7;
/// PADS.ISO (isolation latch, bit 8): the RP2350 powers up with every pad
/// isolated, and the latch must be cleared before the pad conducts. The bit is
/// reserved on the RP2040, where clearing it is a harmless no-op.
const pad_isolate: u32 = 1 << 8;

/// SIO GPIO_OUT_SET: writing a 1 drives the matching output high. The RP2350
/// interleaves the GPIO 32+ ("HI") registers, which shifts this offset relative
/// to the RP2040.
const sio_gpio_out_set: u32 = if (is_rp2040) 0x014 else 0x018;
/// SIO GPIO_OE_SET: writing a 1 enables the matching output driver.
const sio_gpio_oe_set: u32 = if (is_rp2040) 0x024 else 0x038;

/// Stores `value` into the 32-bit MMIO register at absolute `address`. The
/// `volatile` access stops the compiler from reordering, merging, or removing
/// writes whose only effect is on hardware.
inline fn write32(address: u32, value: u32) void {
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}

/// Loads the current 32-bit value of the MMIO register at `address`.
inline fn read32(address: u32) u32 {
    return @as(*volatile u32, @ptrFromInt(address)).*;
}

/// Entry point, called by the pico-zdk runtime once it has initialized memory.
pub fn main() void {
    // The two blocks we need released from reset, as a single bit mask.
    const gpio_blocks = reset_io_bank0 | reset_pads_bank0;

    // 1. Release IO_BANK0 and PADS_BANK0 from reset. Both power up held in
    //    reset; writing their bits to the RESET register's atomic-clear alias
    //    releases exactly those two blocks and leaves everything else alone.
    write32(resets_base + atomic_clr + resets_reset, gpio_blocks);

    // 2. Wait until the hardware confirms both blocks have left reset before
    //    configuring them; writes to a block still in reset are ignored.
    while (read32(resets_base + resets_reset_done) & gpio_blocks != gpio_blocks) {}

    // 3. Pre-load the SIO output latch high, so the pin reaches the lit state
    //    the instant its driver is enabled (avoids a brief low-going glitch).
    write32(sio_base + sio_gpio_out_set, led_mask);

    // 4. Enable the SIO output driver for GPIO 25 (switch it from input to
    //    output). The value was set first, so this immediately drives high.
    write32(sio_base + sio_gpio_oe_set, led_mask);

    // 5. Enable the physical pad: clear output-disable and (on the RP2350) the
    //    isolation latch, through the pad register's atomic-clear alias.
    write32(pads_bank0_base + atomic_clr + gpio25_pad, pad_output_disable | pad_isolate);

    // 6. Point the pad's function mux at SIO. Until now GPIO 25 was not wired to
    //    the SIO value set above; this final write hands the pin to SIO and the
    //    LED turns on.
    write32(io_bank0_base + gpio25_ctrl, funcsel_sio);
}
