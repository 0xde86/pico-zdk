/* RP2040 second-stage flash bootloader link layout.
 *
 * The boot ROM copies the first 256 bytes of flash to the top of SRAM5 and
 * executes them there. The final four bytes of that copy are the boot ROM
 * CRC32, leaving at most 252 bytes for executable boot2 content.
 *
 * This script links only the executable 252-byte boot2 payload. The build
 * step must pad the resulting binary to 252 bytes and append its four-byte
 * checksum before placing the complete blob in the firmware's .boot2 section.
 *
 * Official sources:
 * - RP2040 datasheet, sections 2.2.2, 2.6.2, and 2.8.1:
 *   https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
 * - Raspberry Pi's boot2 linker layout (same address and 252-byte limit):
 *   https://github.com/raspberrypi/pico-sdk/blob/2.3.0/src/rp2040/boot_stage2/boot_stage2.ld
 * - Raspberry Pi's generic 03h boot2 (position-independent, stack-only,
 *   padded to 256 bytes with a four-byte checksum):
 *   https://github.com/raspberrypi/pico-sdk/blob/2.3.0/src/rp2040/boot_stage2/boot2_generic_03h.S
 */

ENTRY(_start)

MEMORY
{
    /* RP2040 SRAM5 is 0x20041000..0x20042000. The boot ROM uses its top
     * 256 bytes for boot2; four of those bytes are reserved for the CRC.
     * Sources: RP2040 datasheet 2.2.2/2.8.1 and pico-sdk boot_stage2.ld above.
     */
    BOOT2 (rx) : ORIGIN = 0x20041f00, LENGTH = 252
}

/* PT_LOAD describes the bytes that the build step extracts from this ELF.
 * ELF gABI, "Program Header" and PT_LOAD:
 * https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.pheader.html
 */
PHDRS
{
    boot2 PT_LOAD FLAGS(5); /* read + execute */
}

SECTIONS
{
    .text ORIGIN(BOOT2) :
    {
        /* The named entry section is kept even when section GC is enabled;
         * remaining code and literal/constant pools follow it. This mirrors
         * the .entry/.text collection in Raspberry Pi's boot_stage2.ld.
         */
        KEEP(*(.text.boot2))
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > BOOT2 :boot2

    /* boot2 must be position-independent and may not depend on mutable
     * statics: flash XIP is not configured while it is running. Raspberry
     * Pi documents both requirements in boot2_generic_03h.S linked above.
     */
    .data :
    {
        *(.data .data.*)
        *(.sdata .sdata.*)
        *(.got .got.*)
    } > BOOT2 :boot2

    .bss (NOLOAD) :
    {
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
    } > BOOT2 :boot2

    /DISCARD/ :
    {
        /* boot2 has no unwinder or runtime initialization. These metadata
         * sections therefore cannot participate in its 252-byte payload.
         * Arm's definitions for EXIDX/EXTAB are in AAELF32:
         * https://github.com/ARM-software/abi-aa/blob/main/aaelf32/aaelf32.rst
         */
        *(.ARM.exidx*)
        *(.ARM.extab*)
        *(.eh_frame*)
        *(.comment)
        *(.note*)
    }

    /* The size and no-static-data checks enforce the constraints stated by
     * Raspberry Pi's boot_stage2.ld and boot2_generic_03h.S.
     */
    ASSERT(SIZEOF(.text) <= LENGTH(BOOT2),
           "RP2040 boot2 exceeds its 252-byte payload limit")
    ASSERT(SIZEOF(.data) == 0,
           "RP2040 boot2 must not contain initialized mutable data")
    ASSERT(SIZEOF(.bss) == 0,
           "RP2040 boot2 must not contain zero-initialized data")
}
