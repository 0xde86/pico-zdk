//! The runtime's default startup init chain.
//!
//! `main` should begin with a known state for the hardware this milestone owns,
//! no matter what ran before it - a warm reset, a bootloader hand-off, or a
//! debugger's "load and run". Debug-critical USB state and later-milestone
//! RTC/HSTX state are deliberately preserved or deferred. This module composes
//! board facts with HAL sequences in the order the hardware requires:
//!
//!     reset almost everything -> release the clk_sys/clk_ref-clocked blocks
//!       -> power down the USB PHY -> clocks and ticks to spec
//!       -> release every M3-configured block -> chip-specific pad fixes
//!
//! The two reset halves exist because a block whose functional clock is stopped
//! never reports itself out of reset. ADC, SPI, UART, and USB have to wait for
//! M3's clock tree; RTC/HSTX remain held for their later milestones. This
//! distinction is explicit because the deferred blocks are not part of M3's
//! otherwise-known startup state.
//!
//! Applications own their pins - mux, pad, direction, and value. They do not
//! have to repeat any of the below.

const config = @import("config");
const zdk = @import("pico_zdk");

/// Runs the default init chain. Called by `_start` before `main` unless the
/// firmware selected `.reset_state`.
///
/// **Contains unbounded waits.** The crystal, the PLL locks, and each reset
/// release are all polled without a timeout, because the timebase a timeout
/// needs is what this chain is building. A board with no working crystal hangs
/// here rather than running at an unknown speed.
pub fn spec() void {
    // A known peripheral state, whatever ran before. The mask spares the QSPI
    // flash interface this code executes from, the PLLs whose clock muxing is
    // not yet reset-safe, and the USB and syscfg blocks that USB-to-SWD debug
    // setups depend on.
    zdk.resets.resetMask(zdk.chip.resets.early_reset_mask);
    zdk.resets.releaseMaskAndWait(zdk.chip.resets.early_release_mask);

    usbPhyPowerDown();

    // The crystal, both PLLs, every configured generator, and the tick domains.
    zdk.clocks.applySpecDefaults(zdk.board.xosc_hz);

    // M3's peripheral clocks exist now, so the blocks that were waiting on
    // those clocks can come out of reset. RTC/HSTX deliberately remain reset
    // until their later milestones configure their clocks; claiming every
    // block here would overstate the startup contract. The timer is included,
    // so M4 can count from `main` entry with no timer-specific startup step.
    zdk.resets.releaseMaskAndWait(zdk.chip.resets.post_clock_release_mask);

    adcPadInputDisable();
}

/// Powers down the USB PHY, unless something is already using the controller.
///
/// The PHY draws current from reset until M14 needs it. The guard compares
/// `SIE_CTRL` against its documented reset word - which differs between the
/// chips - so a controller already configured by a debugger or by core 1 acting
/// as one is left strictly alone.
inline fn usbPhyPowerDown() void {
    const usb = zdk.chip.usb;
    const current: u32 = @bitCast(usb.registers.sie_ctrl.read());
    if (current != comptime @as(u32, @bitCast(usb.SieCtrl{}))) return;
    usb.registers.sie_ctrl.setBits(usb.transceiver_pd_mask);
}

/// Disables the digital input buffers on the RP2040's ADC-capable pads.
///
/// GPIO 26-29 are the analog inputs. A mid-rail voltage on a pad whose digital
/// input buffer is enabled leaks current through that buffer on RP2040 B0/B1
/// silicon. RP2350 already resets these pads correctly, so the whole function
/// compiles away there. `gpio.setFunction` re-enables the buffer per pin when a
/// pin is actually claimed for digital use.
inline fn adcPadInputDisable() void {
    if (config.chip != .rp2040) return;
    inline for (.{ 26, 27, 28, 29 }) |pin| zdk.gpio.setInputEnable(pin, false);
}
