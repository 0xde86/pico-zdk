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
        \\ ldr r3, =0x18000000   // r3 = XIP_SSI base: the flash serial-interface registers
        \\ movs r0, #0
        \\ str r0, [r3, #0x08]   // SSIENR (+0x08) = 0: disable SSI so its config is writable
        \\ movs r0, #4
        \\ str r0, [r3, #0x14]   // BAUDR (+0x14) = 4: SCK = clk_sys / 4 (safe, chip-agnostic)
        \\ ldr r0, =0x001f0300   // CTRLR0: standard SPI, 32-bit data frame (DFS_32=31), EEPROM-read TMOD
        \\ str r0, [r3, #0x00]   // -> CTRLR0 (+0x00)
        \\ ldr r0, =0x03000218   // SPI_CTRLR0: XIP cmd=0x03, 8-bit instr, 24-bit addr (ADDR_L=6), 0 dummy
        \\ ldr r1, =0x180000f4   // r1 = &SPI_CTRLR0 (XIP_SSI base + 0xf4)
        \\ str r0, [r1]          // -> SPI_CTRLR0
        \\ movs r0, #0
        \\ str r0, [r3, #0x04]   // CTRLR1 (+0x04) = 0: frame count (NDF) unused under XIP
        \\ movs r0, #1
        \\ str r0, [r3, #0x08]   // SSIENR (+0x08) = 1: re-enable SSI; flash is now XIP-mapped
        \\ ldr r0, =0x10000100   // r0 = app vector table: flash base 0x1000_0000 + 256-byte boot2
        \\ ldr r1, =0xe000ed08   // r1 = SCB VTOR (Vector Table Offset Register)
        \\ str r0, [r1]          // VTOR = 0x1000_0100: CPU now uses the app's vector table
        \\ ldr r1, [r0, #0]      // r1 = vectors[0] = the app's initial main stack pointer
        \\ ldr r0, [r0, #4]      // r0 = vectors[1] = the app's reset handler (entry point)
        \\ msr msp, r1           // MSP = app stack pointer
        \\ bx r0                 // branch to the reset handler (address LSB=1 keeps Thumb state)
    );
}
