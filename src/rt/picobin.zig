//! RP2350 picobin block and item encoding.
//!
//! Picobin is the metadata format consumed by the RP2350 boot ROM. M1 uses an
//! `IMAGE_TYPE` item and, for RISC-V, an `ENTRY_POINT` item. Later milestones
//! extend the same block loop with hashes, signatures, versions, and partition
//! tables.
//!
//! Source: RP2350 datasheet section 5.1.5 and Raspberry Pi's public constants:
//! https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
//! https://github.com/raspberrypi/pico-sdk/blob/master/src/common/boot_picobin_headers/include/boot/picobin.h

const std = @import("std");

/// Marker beginning every picobin metadata block.
pub const block_marker_start: u32 = 0xffffded3;

/// Marker ending every picobin metadata block.
pub const block_marker_end: u32 = 0xab123579;

/// One-byte item tag for `IMAGE_TYPE`.
pub const image_type_tag: u8 = 0x42;

/// One-byte item tag for `ENTRY_POINT`.
pub const entry_point_tag: u8 = 0x44;

/// Two-byte item tag for the final item in a block.
pub const last_item_tag: u8 = 0xff;

/// Executable CPU architecture encoded in an `IMAGE_TYPE` item.
pub const Cpu = enum(u3) {
    arm = 0,
    riscv = 1,
    varmulet = 2,
};

/// Arm security state encoded in an executable `IMAGE_TYPE` item.
pub const Security = enum(u2) {
    unspecified = 0,
    non_secure = 1,
    secure = 2,
};

/// Kind of picobin image, encoded in the low nibble of an `IMAGE_TYPE` item.
pub const ImageKind = enum(u4) {
    invalid = 0,
    executable = 1,
    data = 2,
};

/// Chip family encoded in an executable `IMAGE_TYPE` item.
pub const Chip = enum(u3) {
    rp2040 = 0,
    rp2350 = 1,
};

/// Bit layout of the 16-bit `IMAGE_TYPE` value, LSB-first. Mirrors picobin.h's
/// `PICOBIN_IMAGE_TYPE_*` fields (see module-header sources).
const ImageTypeBits = packed struct(u16) {
    kind: ImageKind,
    security: Security,
    _reserved0: u2 = 0,
    cpu: Cpu,
    _reserved1: u1 = 0,
    chip: Chip,
    try_before_you_buy: bool,
};

/// Fields supported by the M1 executable `IMAGE_TYPE` item.
pub const ImageType = struct {
    cpu: Cpu,
    security: Security = .unspecified,
    try_before_you_buy: bool = false,

    /// Encodes the 16-bit `IMAGE_TYPE` value for an RP2350 executable.
    pub fn encode(self: ImageType) u16 {
        return @bitCast(ImageTypeBits{
            .kind = .executable,
            .security = self.security,
            .cpu = self.cpu,
            .chip = .rp2350,
            .try_before_you_buy = self.try_before_you_buy,
        });
    }
};

/// Leading word shared by short picobin items: a one-byte tag, a one-byte size
/// in 32-bit words, and two type-specific bytes. Fields are LSB-first.
const ItemHeader = packed struct(u32) {
    tag: u8,
    size_words: u8,
    data: u16 = 0,
};

/// Leading word of a block's final item: a one-byte tag, a two-byte size in
/// words, and a padding byte. Fields are LSB-first.
const LastItem = packed struct(u32) {
    tag: u8,
    size_words: u16,
    _reserved0: u8 = 0,
};

/// Encodes a one-word item header with an inline 16-bit value.
pub fn oneWordItem(tag: u8, value: u16) u32 {
    return @bitCast(ItemHeader{ .tag = tag, .size_words = 1, .data = value });
}

/// Encodes the three-word `ENTRY_POINT` item header.
pub fn entryPointHeader() u32 {
    return @bitCast(ItemHeader{ .tag = entry_point_tag, .size_words = 3 });
}

/// Encodes the block's final item. `item_words` excludes the start marker,
/// final item, next-block offset, and end marker.
pub fn lastItem(item_words: u16) u32 {
    return @bitCast(LastItem{ .tag = last_item_tag, .size_words = item_words });
}

/// Returns the type of a self-looping picobin block containing `Items`.
///
/// `Items` is an `extern struct` of complete item words and relocatable pointer
/// fields. This keeps the framing generic so later hash, signature, version,
/// and partition items can extend the block without rewriting its envelope.
pub fn Block(comptime Items: type) type {
    if (@sizeOf(Items) == 0 or @sizeOf(Items) % @sizeOf(u32) != 0) {
        @compileError("picobin items must occupy a non-zero whole number of words");
    }
    const item_words = @sizeOf(Items) / @sizeOf(u32);
    if (item_words > std.math.maxInt(u16)) {
        @compileError("picobin block has too many item words");
    }

    return extern struct {
        marker_start: u32,
        items: Items,
        last_item: u32,
        next_block_offset: i32,
        marker_end: u32,

        /// Wraps item data in the markers and self-loop terminator required by
        /// the RP2350 boot ROM.
        pub fn init(items: Items) @This() {
            return .{
                .marker_start = block_marker_start,
                .items = items,
                .last_item = lastItem(item_words),
                .next_block_offset = 0,
                .marker_end = block_marker_end,
            };
        }
    };
}

/// Block payload for the RiscV executable block.
pub const RiscvItems = extern struct {
    image_type: u32,
    entry_header: u32,
    entry_point: *const anyopaque,
    stack_pointer: *const anyopaque,
};

/// Block payload for the minimal Arm Secure executable block.
pub const ArmSecureItems = extern struct {
    image_type: u32,
};

test "Arm Secure IMAGE_DEF block" {
    const block = Block(ArmSecureItems).init(.{
        .image_type = oneWordItem(image_type_tag, (ImageType{ .cpu = .arm, .security = .secure }).encode()),
    });
    try std.testing.expectEqualSlices(u32, &.{
        0xffffded3, // block_marker_start
        0x10210142, // IMAGE_TYPE item: executable, secure, Arm, RP2350
        0x000001ff, // LAST item covering 1 word of items
        0x00000000, // next-block offset (self-loop)
        0xab123579, // block_marker_end
    }, std.mem.bytesAsSlice(u32, std.mem.asBytes(&block)));
}

test "RISC-V IMAGE_DEF block" {
    const block = Block(RiscvItems).init(.{
        .image_type = oneWordItem(image_type_tag, (ImageType{ .cpu = .riscv }).encode()),
        .entry_header = entryPointHeader(),
        .entry_point = @ptrFromInt(0x10000034), // example _start address
        .stack_pointer = @ptrFromInt(0x20082000), // example __stack_top address
    });
    // Checked field by field rather than as one u32 slice like the Arm block:
    // RiscvItems holds two real pointers, 8 bytes each on a 64-bit test host, so
    // the raw block layout (item count, pointer widths) is host-dependent. Every
    // field below is host-independent; image_check.sh validates the full on-target
    // byte layout, including last_item = 0x000004ff (4 words on the 32-bit chip).
    try std.testing.expectEqual(@as(u32, 0xffffded3), block.marker_start);
    try std.testing.expectEqual(@as(u32, 0x11010142), block.items.image_type); // IMAGE_TYPE: executable, RISC-V, RP2350
    try std.testing.expectEqual(@as(u32, 0x00000344), block.items.entry_header); // ENTRY_POINT header (3 words)
    try std.testing.expectEqual(@as(usize, 0x10000034), @intFromPtr(block.items.entry_point));
    try std.testing.expectEqual(@as(usize, 0x20082000), @intFromPtr(block.items.stack_pointer));
    try std.testing.expectEqual(@as(i32, 0), block.next_block_offset); // self-loop
    try std.testing.expectEqual(@as(u32, 0xab123579), block.marker_end);
}
