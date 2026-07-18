//! RP2040 boot2 checksum calculator

const std = @import("std");

/// Executable bytes available before the checksum word.
pub const payload_size = 252;

/// Complete boot2 size consumed by the RP2040 boot ROM.
pub const image_size = 256;

/// Computes the RP2040 boot2 CRC over an exactly 252-byte padded payload.
///
/// This is CRC-32/MPEG-2: polynomial `0x04c11db7`, initial value
/// `0xffffffff`, MSB-first, and no final XOR.
pub fn checksum(payload: *const [payload_size]u8) u32 {
    return std.hash.crc.Crc32Mpeg2.hash(payload);
}

/// Returns the padded payload followed by its little-endian checksum word.
pub fn makeImage(payload: []const u8) error{PayloadTooLarge}![image_size]u8 {
    if (payload.len > payload_size) return error.PayloadTooLarge;

    var image = [_]u8{0} ** image_size;
    @memcpy(image[0..payload.len], payload);
    std.mem.writeInt(u32, image[payload_size..image_size], checksum(image[0..payload_size]), .little);
    return image;
}

test "CRC-32/MPEG-2 check value" {
    var payload = [_]u8{0} ** payload_size;
    @memcpy(payload[0..9], "123456789");

    var expected = std.hash.crc.Crc32Mpeg2.init();
    expected.update(&payload);
    try std.testing.expectEqual(expected.final(), checksum(&payload));
    try std.testing.expectEqual(@as(u32, 0x0376e6e7), std.hash.crc.Crc32Mpeg2.hash("123456789"));
}

test "image is padded and checksum is little-endian" {
    const image = try makeImage(&.{ 0xaa, 0x55 });
    try std.testing.expectEqual(@as(u8, 0xaa), image[0]);
    try std.testing.expectEqual(@as(u8, 0x55), image[1]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** (payload_size - 2)), image[2..payload_size]);
    try std.testing.expectEqual(checksum(image[0..payload_size]), std.mem.readInt(u32, image[payload_size..], .little));
}
