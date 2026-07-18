//! UF2 ("USB Flashing Format") block encoding.
//!
//! UF2 is Microsoft's drag-and-drop flashing container: a flat stream of
//! fixed 512-byte, self-describing blocks. Each block carries a chunk of the
//! image plus the absolute flash address it belongs at, so copying the file
//! onto the board's BOOTSEL mass-storage device is enough to program it - no
//! host driver or protocol needed.
//!
//! This module is the pure, host-testable encoder (no ELF, no I/O); the CLI in
//! `main.zig` wraps it. Every constant below is sourced from:
//!
//!   - UF2 specification (block layout, magic numbers, flags):
//!     https://github.com/microsoft/uf2/blob/master/README.md
//!   - Raspberry Pi UF2 family-ID registrations:
//!     https://github.com/microsoft/uf2/blob/master/utils/uf2families.json
//!   - RP2350 datasheet section 5.5 "UF2 format" (Raspberry Pi's use of it):
//!     https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf

const std = @import("std");

/// A UF2 block is always exactly 512 bytes.
/// Source: https://github.com/microsoft/uf2/blob/master/README.md
pub const block_size = 512;

/// Bytes 0..32 are the fixed header of eight little-endian `u32` fields.
pub const header_size = 32;

/// The `data` field spans the space between the header and the 4-byte trailing
/// magic: 512 - 32 - 4 = 476 bytes.
pub const data_capacity = block_size - header_size - 4;

/// Bytes of real payload per block. The UF2 spec allows up to `data_capacity`,
/// but Raspberry Pi (and picotool) use 256, matching the flash program page.
/// Source: RP2350 datasheet 5.5; pico-sdk `tools/elf2uf2`.
pub const payload_size = 256;

/// First header magic word: the ASCII bytes "UF2\n" in little-endian order
/// (0x55 'U', 0x46 'F', 0x32 '2', 0x0A '\n').
/// Source: https://github.com/microsoft/uf2/blob/master/README.md
pub const magic_start_0: u32 = 0x0a32_4655;

/// Second header magic word, a fixed random constant that disambiguates the
/// first from a coincidental "UF2\n" occurrence.
pub const magic_start_1: u32 = 0x9e5d_5157;

/// Trailing magic word at offset 508, letting a reader detect a truncated block.
pub const magic_end: u32 = 0x0ab1_6f30;

/// UF2 `flags`: bit 13 (`0x2000`) declares that the `file_size` header field
/// instead carries a family ID, so the bootloader only accepts blocks meant for
/// this exact chip/image type.
/// Source: https://github.com/microsoft/uf2/blob/master/README.md ("Flags")
pub const flag_family_id_present: u32 = 0x0000_2000;

/// UF2 family IDs registered by Raspberry Pi. The BOOTSEL bootloader checks
/// these so, e.g., a Pico 2 refuses an RP2040 image and an Arm core refuses a
/// RISC-V image.
/// Source: https://github.com/microsoft/uf2/blob/master/utils/uf2families.json
pub const FamilyId = enum(u32) {
    rp2040 = 0xe48b_ff56,
    rp2350_arm_s = 0xe48b_ff59,
    rp2350_riscv = 0xe48b_ff5a,
};

comptime {
    // Page-aligning target addresses in the CLI assumes a power-of-two payload.
    std.debug.assert(std.math.isPowerOfTwo(payload_size));
    std.debug.assert(payload_size <= data_capacity);
}

/// Encodes one 512-byte UF2 block in place.
///
/// `payload` (<= `payload_size` bytes) is placed at the data field and the rest
/// of the block is zero-filled. `target_addr` is the absolute flash address the
/// payload is programmed to. `block_no` is the 0-based index of this block and
/// `num_blocks` the total count in the file.
pub fn writeBlock(
    block: *[block_size]u8,
    target_addr: u32,
    block_no: u32,
    num_blocks: u32,
    family_id: u32,
    payload: []const u8,
) void {
    std.debug.assert(payload.len <= payload_size);

    @memset(block, 0);
    std.mem.writeInt(u32, block[0..4], magic_start_0, .little);
    std.mem.writeInt(u32, block[4..8], magic_start_1, .little);
    std.mem.writeInt(u32, block[8..12], flag_family_id_present, .little);
    std.mem.writeInt(u32, block[12..16], target_addr, .little);
    std.mem.writeInt(u32, block[16..20], @intCast(payload.len), .little);
    std.mem.writeInt(u32, block[20..24], block_no, .little);
    std.mem.writeInt(u32, block[24..28], num_blocks, .little);
    std.mem.writeInt(u32, block[28..32], family_id, .little);
    @memcpy(block[header_size..][0..payload.len], payload);
    std.mem.writeInt(u32, block[block_size - 4 .. block_size], magic_end, .little);
}

test "magic_start_0 encodes the ASCII tag \"UF2\\n\"" {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, magic_start_0, .little);
    try std.testing.expectEqualSlices(u8, "UF2\n", &bytes);
}

test "family ids match the Raspberry Pi UF2 assignments" {
    try std.testing.expectEqual(@as(u32, 0xe48b_ff56), @intFromEnum(FamilyId.rp2040));
    try std.testing.expectEqual(@as(u32, 0xe48b_ff59), @intFromEnum(FamilyId.rp2350_arm_s));
    try std.testing.expectEqual(@as(u32, 0xe48b_ff5a), @intFromEnum(FamilyId.rp2350_riscv));
}

test "writeBlock lays out header, payload, and trailer" {
    var block: [block_size]u8 = undefined;
    const payload = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    writeBlock(&block, 0x1000_0100, 2, 5, @intFromEnum(FamilyId.rp2350_riscv), &payload);

    const rd = std.mem.readInt;
    try std.testing.expectEqual(magic_start_0, rd(u32, block[0..4], .little));
    try std.testing.expectEqual(magic_start_1, rd(u32, block[4..8], .little));
    try std.testing.expectEqual(flag_family_id_present, rd(u32, block[8..12], .little));
    try std.testing.expectEqual(@as(u32, 0x1000_0100), rd(u32, block[12..16], .little));
    try std.testing.expectEqual(@as(u32, payload.len), rd(u32, block[16..20], .little));
    try std.testing.expectEqual(@as(u32, 2), rd(u32, block[20..24], .little));
    try std.testing.expectEqual(@as(u32, 5), rd(u32, block[24..28], .little));
    try std.testing.expectEqual(@as(u32, 0xe48b_ff5a), rd(u32, block[28..32], .little));

    try std.testing.expectEqualSlices(u8, &payload, block[header_size .. header_size + payload.len]);
    // Everything between the payload and the trailing magic is zero-filled.
    try std.testing.expect(std.mem.allEqual(u8, block[header_size + payload.len .. block_size - 4], 0));
    try std.testing.expectEqual(magic_end, rd(u32, block[block_size - 4 .. block_size], .little));
}
