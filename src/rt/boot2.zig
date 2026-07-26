//! RP2040 generic `03h` second-stage flash bootloader.
//!
//! The boot ROM copies this code to `0x2004_1f00` and executes it from SRAM5.
//! It configures the DW_apb_ssi controller for conservative single-bit `03h`
//! reads, installs the application vector table, and enters its reset handler.
//!
//! Sources: RP2040 datasheet sections 2.8.1 and 4.10, and Raspberry Pi's
//! `boot2_generic_03h.S` reference implementation:
//! https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
//! https://github.com/raspberrypi/pico-sdk/blob/2.3.0/src/rp2040/boot_stage2/boot2_generic_03h.S

/// Configures serial `03h` XIP and enters the vector table at `0x1000_0100`.
///
/// This function is naked and position-independent because its link address is
/// the SRAM address used by the boot ROM, while its bytes are stored in flash.
/// Configure the DW_apb_ssi flash controller for plain single-bit `03h`
/// reads, then boot the application. Register offsets are from the XIP_SSI
/// block at 0x1800_0000 (RP2040 datasheet 4.10.13); the SSI must be disabled
/// (SSIENR=0) while its CTRLR0/SPI_CTRLR0/BAUDR registers are rewritten.
pub export fn _start() linksection(".text.boot2") callconv(.naked) noreturn {
    asm volatile (
        \\ ldr r3, =0x18000000 // Materialize XIP_SSI_BASE so boot2 can configure flash before XIP reads are usable.
        \\ movs r0, #0         // Prepare the disabled value required before changing protected SSI configuration.
        \\ str r0, [r3, #0x08] // Clear SSIENR so CTRLR0, SPI_CTRLR0, and BAUDR accept the following writes.
        \\ movs r0, #4         // Choose the conservative divide-by-four serial clock used by generic 03h boot.
        \\ str r0, [r3, #0x14] // Program BAUDR so initial flash reads do not exceed broadly supported SCK rates.
        \\ ldr r0, =0x001f0300 // Encode standard SPI, 32-bit frames, and EEPROM-read mode required by XIP reads.
        \\ str r0, [r3, #0x00] // Program CTRLR0 while SSI is disabled so the controller accepts the new frame mode.
        \\ ldr r0, =0x03000218 // Encode command 03h, 8 instruction bits, 24 address bits, and no dummy cycles.
        \\ ldr r1, =0x180000f4 // Materialize SPI_CTRLR0 directly because its offset exceeds Thumb-1 STR-immediate range.
        \\ str r0, [r1]        // Program the XIP transaction format so mapped reads issue generic 03h commands.
        \\ movs r0, #0         // Encode NDF=0, which the SSI defines as one 32-bit receive frame in EEPROM-read mode.
        \\ str r0, [r3, #0x04] // Program CTRLR1 so each translated XIP access performs the required single-frame read.
        \\ movs r0, #1         // Prepare the enable bit only after every SSI configuration register is complete.
        \\ str r0, [r3, #0x08] // Re-enable SSI so the application image becomes readable through the XIP window.
        \\ ldr r0, =0x10000100 // Select the application vectors immediately after the mandatory 256-byte boot2 block.
        \\ ldr r1, =0xe000ed08 // Materialize SCB_VTOR so exceptions switch from ROM vectors to application vectors.
        \\ str r0, [r1]        // Install the application table before its reset handler can fault or receive an interrupt.
        \\ dsb                 // Complete the VTOR write so every subsequent exception uses the application vectors.
        \\ ldr r1, [r0, #0]    // Fetch the application's initial MSP because boot2's ROM-provided stack must not leak in.
        \\ ldr r0, [r0, #4]    // Fetch the reset handler chosen by the application rather than assuming a code offset.
        \\ msr msp, r1         // Install the application stack before entering any generated startup code.
        \\ bx r0               // Enter its reset handler via BX so the vector's required Thumb-state bit is honored.
    );
}
