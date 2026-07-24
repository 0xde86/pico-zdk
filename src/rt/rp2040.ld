/* RP2040 flash-resident firmware layout for Raspberry Pi Pico.
 *
 * Flash begins with the mandatory 256-byte, checksummed second-stage
 * bootloader. boot2 configures XIP and enters the vector table immediately
 * following it at 0x10000100.
 *
 * Official sources:
 * - RP2040 datasheet, sections 2.2.2 (address map), 2.6 (memory), and
 *   2.8.1 (processor-controlled boot):
 *   https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
 * - Raspberry Pi's canonical RP2040 flash linker layout:
 *   https://github.com/raspberrypi/pico-sdk/blob/2.3.0/src/rp2_common/pico_crt0/rp2040/memmap_default.ld
 * - Raspberry Pi Pico board definition (2 MiB installed flash):
 *   https://github.com/raspberrypi/pico-sdk/blob/2.3.0/src/boards/include/boards/pico.h
 * - Raspberry Pi boot2 layout and generic 03h implementation:
 *   https://github.com/raspberrypi/pico-sdk/blob/2.3.0/src/rp2040/boot_stage2/boot_stage2.ld
 *   https://github.com/raspberrypi/pico-sdk/blob/2.3.0/src/rp2040/boot_stage2/boot2_generic_03h.S
 */

ENTRY(_start)

MEMORY
{
    /* XIP_BASE and SRAM bank boundaries come from RP2040 datasheet 2.2.2.
     * The 2 MiB FLASH length is a Pico board property from boards/pico.h.
     * Splitting the final two 4 KiB SRAM banks follows pico-sdk's canonical
     * memmap: SRAM4 is reserved for a future core-1 stack and SRAM5 is the
     * core-0 stack. This also gives the documented SRAM_END 0x20042000.
     */
    FLASH     (rx)  : ORIGIN = 0x10000000, LENGTH = 2M
    RAM       (rwx) : ORIGIN = 0x20000000, LENGTH = 256K
    SCRATCH_X (rwx) : ORIGIN = 0x20040000, LENGTH = 4K
    STACK     (rw)  : ORIGIN = 0x20041000, LENGTH = 4K
}

/* Explicit PT_LOAD entries keep ELF headers out of the physical flash image
 * and distinguish .data's flash load address from its SRAM virtual address.
 * ELF gABI program-header semantics:
 * https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.pheader.html
 */
PHDRS
{
    flash    PT_LOAD FLAGS(5); /* read + execute */
    ram_init PT_LOAD FLAGS(6); /* read + write, loaded from flash */
    ram      PT_LOAD FLAGS(6); /* read + write, zero-filled */
}

SECTIONS
{
    .boot2 ORIGIN(FLASH) :
    {
        /* RP2040 boot ROM consumes the first 256 flash bytes as boot2.
         * Sources: RP2040 datasheet 2.8.1 and pico-sdk boot_stage2.ld.
         */
        __flash_binary_start = .;
        __boot2_start = .;
        KEEP(*(.boot2))
        __boot2_end = .;
    } > FLASH :flash

    ASSERT(SIZEOF(.boot2) == 0x100,
           "RP2040 boot2 must be exactly 256 bytes including its CRC32")

    .vectors :
    {
        /* boot2_generic_03h.S states that cold boot continues through the
         * vector table at 0x10000100. pico-sdk memmap_default.ld places
         * KEEP(*(.vectors)) immediately after its exact-size .boot2.
         */
        __vector_table = .;
        KEEP(*(.vectors))
        __vector_table_end = .;
    } > FLASH :flash

    ASSERT(ADDR(.vectors) == ORIGIN(FLASH) + 0x100,
           "RP2040 vector table must begin at 0x10000100")
    ASSERT(SIZEOF(.vectors) != 0,
           "RP2040 vector table is missing")

    .text :
    {
        /* Section ordering and KEEP(.reset) follow pico-sdk's canonical
         * RP2040 memmap linked in the file header.
         */
        KEEP(*(.reset))
        *(.text .text.*)
        . = ALIGN(4);
    } > FLASH :flash

    .rodata :
    {
        /* Zig constants, RISC-V-compatible small read-only data names, unwind
         * metadata, and initialization arrays all remain in the flash image.
         * Arm section types and initialization-array rules are specified by:
         * https://github.com/ARM-software/abi-aa/blob/main/aaelf32/aaelf32.rst
         */
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.eh_frame_hdr)
        *(.eh_frame .eh_frame.*)
        KEEP(*(.init_array .init_array.*))
        . = ALIGN(4);
    } > FLASH :flash

    .ARM.extab :
    {
        /* Keep Arm exception tables in their ABI-defined output sections;
         * combining SHT_ARM_EXIDX with ordinary PROGBITS is invalid.
         * Source: AAELF32 section 5.3, linked above.
         */
        *(.ARM.extab* .gnu.linkonce.armextab.*)
    } > FLASH :flash

    __exidx_start = .;
    .ARM.exidx :
    {
        *(.ARM.exidx* .gnu.linkonce.armexidx.*)
    } > FLASH :flash
    __exidx_end = .;

    .data :
    {
        /* Runtime VMA is SRAM, while AT > FLASH assigns the initialization
         * bytes a flash LMA. This is the same arrangement and symbol contract
         * used by Raspberry Pi's RP2040 memmap_default.ld.
         */
        . = ALIGN(4);
        __data_start = .;
        *(.sdata .sdata.*)
        *(.data .data.*)
        *(.got .got.*)
        . = ALIGN(4);
        __data_end = .;
    } > RAM AT > FLASH :ram_init

    __data_load_start = LOADADDR(.data);
    __data_load_end = LOADADDR(.data) + SIZEOF(.data);

    .bss (NOLOAD) :
    {
        /* NOLOAD gives zero-initialized storage an SRAM VMA without adding
         * bytes to the flash image, matching pico-sdk memmap_default.ld.
         */
        . = ALIGN(4);
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM :ram

    /* Core 0 uses the dedicated SRAM5 bank. __stack_top equals the RP2040
     * SRAM_END documented in datasheet 2.2.2 and used by pico-sdk's memmap.
     * The stronger 16-byte alignment also satisfies Arm AAPCS32 stack rules:
     * https://github.com/ARM-software/abi-aa/blob/main/aapcs32/aapcs32.rst
     */
    __stack_bottom = ORIGIN(STACK);
    __stack_top = ORIGIN(STACK) + LENGTH(STACK);

    /* The UF2 converter uses the ELF PT_LOAD physical/load addresses,
     * including initialized RAM data, rather than .data's SRAM VMA.
     * Source: ELF gABI program-header specification linked above.
     */
    __flash_binary_end = LOADADDR(.data) + SIZEOF(.data);

    ASSERT(__bss_end <= ORIGIN(RAM) + LENGTH(RAM),
           "RP2040 application RAM overflow")
    ASSERT((__stack_top & 0xf) == 0,
           "RP2040 stack top must be 16-byte aligned")
}
