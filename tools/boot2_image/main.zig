//! boot2 image tool: turn the linked RP2040 boot2 ELF into the generated Zig
//! module the firmware runtime embeds.
//!
//! This is a small host program the build graph runs via `b.addRunArtifact`.
//! It extracts the boot2 `.text`, appends the RP2040 boot ROM checksum, and
//! writes a `boot2_image.zig` source file. The checksum math and its unit
//! tests live in `boot2_crc.zig`.
//!
//! Usage:
//!     boot2_image <input.elf> <output.zig>

const std = @import("std");
const boot2_crc = @import("boot2_crc.zig");

const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // The arena is freed wholesale on exit; a short-lived tool never frees.
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer args.deinit();
    _ = args.skip(); // executable name
    const elf_path = args.next() orelse return error.MissingInputArg;
    const out_path = args.next() orelse return error.MissingOutputArg;

    const source = try elfToBoot2Source(arena, io, elf_path);

    const out = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out.close(io);
    try out.writeStreamingAll(io, source);
}

/// Extracts the boot2 `.text` from the ELF at `elf_path`, checksums it into the
/// 256-byte flash image, and formats the generated `boot2_image.zig` source.
fn elfToBoot2Source(gpa: Allocator, io: std.Io, elf_path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, elf_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);

    const read_buffer = try gpa.alloc(u8, 8192);
    var reader = std.Io.File.Reader.initSize(file, io, read_buffer, stat.size);
    const header = try std.elf.Header.read(&reader.interface);

    // Resolve section names, then locate `.text`.
    const string_header_offset = header.shoff + @as(u64, header.shentsize) * header.shstrndx;
    try reader.seekTo(string_header_offset);
    const string_header = try std.elf.takeSectionHeader(&reader.interface, header.is_64, header.endian);
    try reader.seekTo(string_header.sh_offset);
    const section_names = try reader.interface.readAlloc(gpa, @intCast(string_header.sh_size));

    var text_header: ?std.elf.Elf64_Shdr = null;
    var sections = header.iterateSectionHeaders(&reader);
    while (try sections.next()) |section| {
        const name_offset: usize = @intCast(section.sh_name);
        const name_end = std.mem.findScalarPos(u8, section_names, name_offset, 0) orelse continue;
        if (std.mem.eql(u8, section_names[name_offset..name_end], ".text")) {
            text_header = section;
            break;
        }
    }

    const text = text_header orelse return error.MissingTextSection;
    if (text.sh_size > boot2_crc.payload_size) return error.PayloadTooLarge;

    try reader.seekTo(text.sh_offset);
    const payload = try reader.interface.readAlloc(gpa, @intCast(text.sh_size));
    const image = try boot2_crc.makeImage(payload);

    // Format the generated module. 256 hex bytes at 16 per line comfortably fit.
    const buffer = try gpa.alloc(u8, 8192);
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll(
        \\//! Generated RP2040 boot2 image. Do not edit.
        \\
        \\/// Checksummed 256-byte image placed at the beginning of flash.
        \\pub export const image linksection(".boot2") = [256]u8{
        \\
    );
    for (image, 0..) |byte, index| {
        if (index % 16 == 0) try writer.writeAll("    ");
        try writer.print("0x{x:0>2},", .{byte});
        try writer.writeByte(if (index % 16 == 15) '\n' else ' ');
    }
    try writer.writeAll("};\n");
    return writer.buffered();
}
