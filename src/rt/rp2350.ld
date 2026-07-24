/* RP2350 flash-resident firmware layout for Raspberry Pi Pico 2.
 *
 * This layout is shared by Cortex-M33 and Hazard3 firmware. Architecture-
 * specific entry information lives in the vector table and IMAGE_DEF block,
 * not in the memory map. The boot ROM searches the first 4 KiB of flash for
 * a valid IMAGE_DEF block loop.
 *
 * Official sources:
 * - RP2350 datasheet, sections 2.2 (address map), 2.2.3 (SRAM), 5.1.5
 *   (block loops), 5.1.12 (flash image boot), and 5.2 (boot sequence):
 *   https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
 * - Raspberry Pi's canonical RP2350 flash linker layout:
 *   https://github.com/raspberrypi/pico-sdk/blob/2.3.0/src/rp2_common/pico_crt0/rp2350/memmap_default.ld
 * - Raspberry Pi's canonical IMAGE_DEF/block-loop emission for Arm/RISC-V:
 *   https://github.com/raspberrypi/pico-sdk/blob/2.3.0/src/rp2_common/pico_crt0/embedded_start_block.inc.S
 * - Raspberry Pi Pico 2 board definition (4 MiB installed flash):
 *   https://github.com/raspberrypi/pico-sdk/blob/2.3.0/src/boards/include/boards/pico2.h
 */

ENTRY(_start)

MEMORY
{
    /* XIP_BASE and SRAM boundaries come from RP2350 datasheet 2.2/2.2.3.
     * The 4 MiB FLASH length is a Pico 2 board property from boards/pico2.h.
     * The 512 KiB striped SRAM plus separate SRAM8/SRAM9 4 KiB banks mirror
     * Raspberry Pi's canonical RP2350 memmap and SRAM_END 0x20082000.
     */
    FLASH     (rx)  : ORIGIN = 0x10000000, LENGTH = 4M
    RAM       (rwx) : ORIGIN = 0x20000000, LENGTH = 512K
    SCRATCH_X (rwx) : ORIGIN = 0x20080000, LENGTH = 4K
    STACK     (rw)  : ORIGIN = 0x20081000, LENGTH = 4K
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
    .vectors ORIGIN(FLASH) :
    {
        /* Arm launches from the vector table at the image start. RISC-V uses
         * the explicit ENTRY_POINT item emitted in IMAGE_DEF, while retaining
         * its trap vector section at the image start. Raspberry Pi uses this
         * ordering in rp2350/memmap_default.ld and embedded_start_block.inc.S.
         */
        __flash_binary_start = .;
        __vector_table = .;
        KEEP(*(.vectors))
        __vector_table_end = .;
    } > FLASH :flash

    ASSERT(SIZEOF(.vectors) != 0,
           "RP2350 vector table is missing")

    .image_def ALIGN(4) :
    {
        /* The RP2350 boot ROM scans aligned words in the first 4 KiB for a
         * valid block loop containing IMAGE_DEF (datasheet 5.1.5/5.1.12).
         * KEEP prevents section GC from removing boot metadata that normal
         * application code does not reference.
         */
        __image_def_start = .;
        KEEP(*(.image_def))
        __image_def_end = .;
    } > FLASH :flash

    ASSERT(SIZEOF(.image_def) != 0,
           "RP2350 IMAGE_DEF block is missing")
    ASSERT(__image_def_end <= ORIGIN(FLASH) + 0x1000,
           "RP2350 IMAGE_DEF block must end within the first 4 KiB")

    .text :
    {
        /* Section ordering and KEEP(.reset) follow Raspberry Pi's canonical
         * RP2350 memmap linked in the file header.
         */
        KEEP(*(.reset))
        *(.text .text.*)
        . = ALIGN(4);
    } > FLASH :flash

    .rodata :
    {
        /* Constants, unwind metadata, and initialization arrays remain in the
         * flash image. Arm section types and initialization-array rules:
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
         * bytes a flash LMA. This follows pico-sdk's RP2350 memmap_default.ld.
         */
        . = ALIGN(4);
        __data_start = .;
        /* Hazard3's gp is initialized from this symbol by RISC-V startup.
         * Keeping small data first puts it within gp's signed 12-bit range.
         * RISC-V ELF psABI register convention and stack alignment:
         * https://github.com/riscv-non-isa/riscv-elf-psabi-doc/blob/master/riscv-cc.adoc
         * Raspberry Pi's RP2350 memmap likewise provides __global_pointer$.
         */
        PROVIDE(__global_pointer$ = . + 0x800);
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

    /* Core 0 uses dedicated SRAM9. __stack_top equals the RP2350 SRAM_END
     * documented in datasheet 2.2.3 and used by pico-sdk's memmap. Sixteen-
     * byte alignment satisfies the RISC-V psABI linked above and is stronger
     * than Arm AAPCS32's public-interface requirement:
     * https://github.com/ARM-software/abi-aa/blob/main/aapcs32/aapcs32.rst
     */
    __stack_bottom = ORIGIN(STACK);
    __stack_top = ORIGIN(STACK) + LENGTH(STACK);

    /* End of the bytes represented by flash-addressed PT_LOAD contents,
     * including .data's initialization image. See the ELF gABI link above.
     */
    __flash_binary_end = LOADADDR(.data) + SIZEOF(.data);

    ASSERT(__bss_end <= ORIGIN(RAM) + LENGTH(RAM),
           "RP2350 application RAM overflow")
    ASSERT((__stack_top & 0xf) == 0,
           "RP2350 stack top must be 16-byte aligned")
}
