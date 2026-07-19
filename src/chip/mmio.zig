//! Access-typed memory-mapped I/O register primitives shared by RP2040 and RP2350.

/// A 32-bit memory-mapped read-only register.
pub fn ReadOnly(comptime T: type) type {
    if (@bitSizeOf(T) != 32) {
        @compileError("ReadOnly(T) requires a 32-bit register value type, got " ++ @typeName(T));
    }

    return extern struct {
        _value: u32,

        const Self = @This();

        /// Returns the register value with one volatile 32-bit load.
        pub fn read(self: *const volatile Self) T {
            return @bitCast(self._value);
        }
    };
}

/// A 32-bit memory-mapped write-only register.
pub fn WriteOnly(comptime T: type) type {
    if (@bitSizeOf(T) != 32) {
        @compileError("WriteOnly(T) requires a 32-bit register value type, got " ++ @typeName(T));
    }

    return extern struct {
        _value: u32,

        const Self = @This();

        /// Replaces the register value with one volatile 32-bit store.
        pub fn write(self: *volatile Self, value: T) void {
            self._value = @bitCast(value);
        }
    };
}

/// A 32-bit memory-mapped read-write register.
pub fn ReadWrite(comptime T: type) type {
    if (@bitSizeOf(T) != 32) {
        @compileError("ReadWrite(T) requires a 32-bit register value type, got " ++ @typeName(T));
    }

    return extern struct {
        _value: u32,

        const Self = @This();

        /// Returns the register value with one volatile 32-bit load.
        pub fn read(self: *const volatile Self) T {
            return @bitCast(self._value);
        }

        /// Replaces the register value with one volatile 32-bit store.
        pub fn write(self: *volatile Self, value: T) void {
            self._value = @bitCast(value);
        }
    };
}

/// The atomic XOR/SET/CLEAR address aliases are features of the
/// Raspberry Pi RP-series bus fabric, not features of the APB standard.
const atomic_xor_alias_offset: usize = 0x1000;
const atomic_set_alias_offset: usize = 0x2000;
const atomic_clear_alias_offset: usize = 0x3000;

/// A 32-bit read-write register that additionally supports the RP-series
/// atomic toggle, set, clear and masked write operations.
pub fn ApbReadWrite(comptime T: type) type {
    if (@bitSizeOf(T) != 32) {
        @compileError("AtomicReadWrite(T) requires a 32-bit register value type, got " ++ @typeName(T));
    }

    return extern struct {
        _value: u32,

        const Self = @This();

        /// Returns the register value with one volatile 32-bit load.
        pub fn read(self: *const volatile Self) T {
            return @bitCast(self._value);
        }

        /// Replaces the register value with one volatile 32-bit store.
        pub fn write(self: *volatile Self, value: T) void {
            self._value = @bitCast(value);
        }

        /// Atomically sets every register bit selected by `mask`.
        pub fn setBits(self: *volatile Self, mask: u32) void {
            self.aliasPointer(atomic_set_alias_offset)._value = mask;
        }

        /// Atomically clears every register bit selected by `mask`.
        pub fn clearBits(self: *volatile Self, mask: u32) void {
            self.aliasPointer(atomic_clear_alias_offset)._value = mask;
        }

        /// Atomically toggles every register bit selected by `mask`.
        pub fn toggleBits(self: *volatile Self, mask: u32) void {
            self.aliasPointer(atomic_xor_alias_offset)._value = mask;
        }

        /// Updates bits selected by `mask` to their corresponding bits in `value`.
        ///
        /// The final XOR-alias write is atomic and preserves concurrent changes
        /// outside `mask`. The preceding read and the alias write are not one
        /// atomic operation; callers must synchronize concurrent writers that
        /// can modify bits inside `mask`.
        pub fn writeMasked(self: *volatile Self, value: u32, mask: u32) void {
            const current: u32 = @bitCast(self.read());
            const changed_bits = (current ^ value) & mask;
            self.toggleBits(changed_bits);
        }

        fn aliasPointer(self: *volatile Self, offset: usize) *volatile Self {
            return @ptrFromInt(@intFromPtr(self) + offset);
        }
    };
}

test "Registers occupy one register word" {
    const std = @import("std");

    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ReadOnly(u32)));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(ReadOnly(u32)));

    try std.testing.expectEqual(@as(usize, 4), @sizeOf(WriteOnly(u32)));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(WriteOnly(u32)));

    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ReadWrite(u32)));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(ReadWrite(u32)));

    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ApbReadWrite(u32)));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(ApbReadWrite(u32)));
}
