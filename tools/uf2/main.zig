//! elf2uf2: pack a linked firmware ELF's flash segments into a UF2 file.
//!
//! This is a small host program the build graph runs via `b.addRunArtifact`.
//! It owns only the ELF reading and CLI plumbing; the pure block encoder and
//! every format constant/source live in `uf2.zig` (and are unit-tested there).
//!
//! Usage:
//!     elf2uf2 <family> <input.elf> <output.uf2>
//!
//! `<family>` is a `uf2.FamilyId` name (`rp2040`, `rp2350_arm_s`,
//! `rp2350_riscv`) so the UF2's family ID matches the target chip/core and the
//! BOOTSEL bootloader accepts it.

const std = @import("std");
const uf2 = @import("uf2.zig");

const Allocator = std.mem.Allocator;

/// RP flash is execute-in-place mapped at 0x1000_0000; we only emit flash
/// images, so every loadable segment must load into this window.
/// Source: RP2040 datasheet section 2.6, RP2350 datasheet section 2.2.
const flash_origin: u32 = 0x1000_0000;

/// Largest supported XIP window (16 MiB), used to sanity-check load addresses.
const flash_window_len: u64 = 16 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // The arena is freed wholesale on exit; a short-lived tool never frees.
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer args.deinit();
    _ = args.skip(); // executable name
    const family_name = args.next() orelse return error.MissingFamilyArg;
    const elf_path = args.next() orelse return error.MissingInputArg;
    const uf2_path = args.next() orelse return error.MissingOutputArg;

    const family = std.meta.stringToEnum(uf2.FamilyId, family_name) orelse
        return error.UnknownUf2Family;

    const bytes = try elfToUf2(arena, io, elf_path, @intFromEnum(family));

    const out = try std.Io.Dir.cwd().createFile(io, uf2_path, .{});
    defer out.close(io);
    try out.writeStreamingAll(io, bytes);
}

/// Reads the firmware ELF at `elf_path` and returns its bytes packed as UF2.
///
/// Loadable segments are scattered into 256-byte pages keyed by their aligned
/// *physical* (load) address: `.data` runs from SRAM, but its initializer bytes
/// live in flash at the load address, which is where they must be programmed.
fn elfToUf2(gpa: Allocator, io: std.Io, elf_path: []const u8, family_id: u32) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, elf_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);

    const read_buffer = try gpa.alloc(u8, 8192);
    var reader = std.Io.File.Reader.initSize(file, io, read_buffer, stat.size);
    const header = try std.elf.Header.read(&reader.interface);

    const page_mask = ~@as(u32, uf2.payload_size - 1);
    var pages: std.AutoArrayHashMapUnmanaged(u32, *[uf2.payload_size]u8) = .empty;

    var program_headers = header.iterateProgramHeaders(&reader);
    while (try program_headers.next()) |ph| {
        if (ph.p_type != std.elf.PT_LOAD or ph.p_filesz == 0) continue;

        const load_addr = std.math.cast(u32, ph.p_paddr) orelse return error.LoadAddressOutOfRange;
        const size = std.math.cast(u32, ph.p_filesz) orelse return error.SegmentTooLarge;
        if (load_addr < flash_origin or
            @as(u64, load_addr) + size > @as(u64, flash_origin) + flash_window_len)
        {
            return error.SegmentOutsideFlash;
        }

        try reader.seekTo(ph.p_offset);
        const segment = try reader.interface.readAlloc(gpa, size);

        var done: u32 = 0;
        while (done < size) {
            const addr = load_addr + done;
            const page_addr = addr & page_mask;
            const in_page = addr - page_addr;
            const chunk = @min(uf2.payload_size - in_page, size - done);

            const gop = try pages.getOrPut(gpa, page_addr);
            if (!gop.found_existing) {
                const page = try gpa.create([uf2.payload_size]u8);
                @memset(page, 0);
                gop.value_ptr.* = page;
            }
            @memcpy(gop.value_ptr.*[in_page..][0..chunk], segment[done..][0..chunk]);
            done += chunk;
        }
    }

    if (pages.count() == 0) return error.NoLoadableSegments;

    // Emit blocks in ascending target-address order. keys() aliases the map's
    // storage, so sort a copy rather than corrupting the map in place.
    const page_addrs = try gpa.dupe(u32, pages.keys());
    std.mem.sort(u32, page_addrs, {}, std.sort.asc(u32));
    const num_blocks: u32 = @intCast(page_addrs.len);

    const out = try gpa.alloc(u8, page_addrs.len * uf2.block_size);
    var block: [uf2.block_size]u8 = undefined;
    for (page_addrs, 0..) |page_addr, index| {
        uf2.writeBlock(&block, page_addr, @intCast(index), num_blocks, family_id, pages.get(page_addr).?);
        @memcpy(out[index * uf2.block_size ..][0..uf2.block_size], &block);
    }
    return out;
}
