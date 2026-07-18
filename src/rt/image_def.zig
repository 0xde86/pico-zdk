//! Target-specific RP2350 `IMAGE_DEF` emission.

const std = @import("std");

const config = @import("rt_config");
const picobin = @import("picobin.zig");
const is_rp2040 = config.board == .pico;
const is_riscv = config.board == .pico2 and config.arch == .riscv;

extern var __stack_top: u8;
extern fn _start() callconv(.naked) noreturn;

const image = if (is_riscv)
    picobin.Block(picobin.RiscvItems).init(.{
        .image_type = picobin.oneWordItem(picobin.image_type_tag, (picobin.ImageType{ .cpu = .riscv }).encode()),
        .entry_header = picobin.entryPointHeader(),
        .entry_point = @ptrCast(&_start),
        .stack_pointer = @ptrCast(&__stack_top),
    })
else
    picobin.Block(picobin.ArmSecureItems).init(.{
        .image_type = picobin.oneWordItem(picobin.image_type_tag, (picobin.ImageType{ .cpu = .arm, .security = .secure }).encode()),
    });

/// Boot metadata discovered by the RP2350 boot ROM in the first 4 KiB.
pub export const image_def linksection(".image_def") = image;

comptime {
    if (is_rp2040) @compileError("RP2350 IMAGE_DEF selected for RP2040");
    if (@sizeOf(@TypeOf(image)) != (if (is_riscv) 32 else 20)) {
        @compileError("unexpected RP2350 IMAGE_DEF size");
    }
}
