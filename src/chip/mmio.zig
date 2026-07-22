//! Access-typed memory-mapped I/O register primitives shared by RP2040 and RP2350.

const std = @import("std");

/// A 32-bit memory-mapped read-only register.
pub fn ReadOnly(comptime T: type) type {
    if (@bitSizeOf(T) != 32) {
        @compileError("ReadOnly(T) requires a 32-bit register value type, got " ++ @typeName(T));
    }

    return extern struct {
        _value: u32,

        const Self = @This();

        /// Returns the register value with one volatile 32-bit load.
        pub inline fn read(self: *const volatile Self) T {
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
        pub inline fn write(self: *volatile Self, value: T) void {
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
        pub inline fn read(self: *const volatile Self) T {
            return @bitCast(self._value);
        }

        /// Replaces the register value with one volatile 32-bit store.
        pub inline fn write(self: *volatile Self, value: T) void {
            self._value = @bitCast(value);
        }
    };
}

/// Returns the register-word mask selecting `field` of register value type `T`.
///
/// Operand builder for `ApbReadWrite.writeMasked`
pub inline fn fieldMask(comptime T: type, comptime field: std.meta.FieldEnum(T)) u32 {
    if (@bitSizeOf(T) != 32) {
        @compileError("fieldMask(T, ...) requires a 32-bit register value type, got " ++ @typeName(T));
    }

    const name = @tagName(field);
    if (name[0] == '_') {
        @compileError("fieldMask: '" ++ name ++ "' is reserved padding of " ++ @typeName(T) ++ ", not a writable field");
    }

    const bits = @bitSizeOf(@FieldType(T, name));
    const ones: u32 = (1 << bits) - 1;
    return ones << @bitOffsetOf(T, name);
}

/// Returns the register-word mask selecting every field in `fields`
pub inline fn fieldsMask(comptime T: type, comptime fields: []const std.meta.FieldEnum(T)) u32 {
    return comptime blk: {
        var mask: u32 = 0;
        for (fields) |field| mask |= fieldMask(T, field);
        break :blk mask;
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
        @compileError("ApbReadWrite(T) requires a 32-bit register value type, got " ++ @typeName(T));
    }

    return extern struct {
        _value: u32,

        const Self = @This();

        /// Returns the register value with one volatile 32-bit load.
        pub inline fn read(self: *const volatile Self) T {
            return @bitCast(self._value);
        }

        /// Replaces the register value with one volatile 32-bit store.
        pub inline fn write(self: *volatile Self, value: T) void {
            self._value = @bitCast(value);
        }

        /// Atomically sets every register bit selected by `mask`.
        pub inline fn setBits(self: *volatile Self, mask: u32) void {
            self.aliasPointer(atomic_set_alias_offset)._value = mask;
        }

        /// Atomically clears every register bit selected by `mask`.
        pub inline fn clearBits(self: *volatile Self, mask: u32) void {
            self.aliasPointer(atomic_clear_alias_offset)._value = mask;
        }

        /// Atomically toggles every register bit selected by `mask`.
        pub inline fn toggleBits(self: *volatile Self, mask: u32) void {
            self.aliasPointer(atomic_xor_alias_offset)._value = mask;
        }

        /// Updates bits selected by `mask` to their corresponding bits in `value`.
        ///
        /// The final XOR-alias write is atomic and preserves concurrent changes
        /// outside `mask`. The preceding read and the alias write are not one
        /// atomic operation; callers must synchronize concurrent writers that
        /// can modify bits inside `mask`.
        pub inline fn writeMasked(self: *volatile Self, value: u32, mask: u32) void {
            const current: u32 = @bitCast(self.read());
            self.toggleBits(maskedToggle(current, value, mask));
        }

        inline fn aliasPointer(self: *volatile Self, offset: usize) *volatile Self {
            return @ptrFromInt(@intFromPtr(self) + offset);
        }
    };
}

/// Returns the XOR operand that changes `current` to `value` on every bit
/// selected by `mask` while leaving unselected bits untouched.
inline fn maskedToggle(current: u32, value: u32, mask: u32) u32 {
    return (current ^ value) & mask;
}

comptime {
    // Stand-in for a real register
    const Ctrl = packed struct(u32) {
        funcsel: u5 = 0,
        _reserved0: u3 = 0,
        out_over: u2 = 0,
        _reserved1: u22 = 0,
    };

    std.debug.assert(fieldMask(Ctrl, .funcsel) == 0x0000_001f);
    std.debug.assert(fieldMask(Ctrl, .out_over) == 0x0000_0300);

    // A field spanning the whole register must not overflow the shift that
    // builds its run of ones.
    const Whole = packed struct(u32) { all: u32 = 0 };
    std.debug.assert(fieldMask(Whole, .all) == 0xffff_ffff);

    // Union, not sum: an empty list selects nothing, and a repeated field
    // cannot widen the mask.
    std.debug.assert(fieldsMask(Ctrl, &.{ .funcsel, .out_over }) == 0x0000_031f);
    std.debug.assert(fieldsMask(Ctrl, &.{}) == 0x0000_0000);
    std.debug.assert(fieldsMask(Ctrl, &.{ .funcsel, .funcsel }) == fieldMask(Ctrl, .funcsel));

    const current: u32 = 0x0000_031f;
    const value: u32 = @bitCast(Ctrl{ .funcsel = 5 });
    const updated = current ^ maskedToggle(current, value, fieldsMask(Ctrl, &.{.funcsel}));
    std.debug.assert(updated == 0x0000_0305);
}

test "maskedToggle updates exactly the bits selected by the mask" {
    const cases = [_]struct { current: u32, value: u32, mask: u32 }{
        // `value` bits outside the mask must not leak into the result.
        .{ .current = 0x0000_0000, .value = 0xFFFF_FFFF, .mask = 0x0000_00FF },
        .{ .current = 0xFFFF_FFFF, .value = 0x0000_0000, .mask = 0x0F0F_0F0F },
        .{ .current = 0xA5A5_A5A5, .value = 0x5A5A_5A5A, .mask = 0xFFFF_0000 },
        // Writing the current value back must be a no-op toggle.
        .{ .current = 0xDEAD_BEEF, .value = 0xDEAD_BEEF, .mask = 0xFFFF_FFFF },
        // An empty mask must never change anything.
        .{ .current = 0x1234_5678, .value = 0x8765_4321, .mask = 0x0000_0000 },
        // Single-field update (funcsel-style low bits).
        .{ .current = 0x0000_001F, .value = 0x0000_0005, .mask = 0x0000_001F },
    };

    for (cases) |case| {
        const result = case.current ^ maskedToggle(case.current, case.value, case.mask);
        try std.testing.expectEqual(case.value & case.mask, result & case.mask);
        try std.testing.expectEqual(case.current & ~case.mask, result & ~case.mask);
    }
}

test "Wrapper method bodies compile for integer and packed-struct value types" {
    const Probe = packed struct(u32) { low: u16 = 0, high: u16 = 0 };
    inline for (.{ u32, Probe }) |T| {
        std.testing.refAllDecls(ReadOnly(T));
        std.testing.refAllDecls(WriteOnly(T));
        std.testing.refAllDecls(ReadWrite(T));
        std.testing.refAllDecls(ApbReadWrite(T));
    }
}

test "Registers occupy one register word" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ReadOnly(u32)));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(ReadOnly(u32)));

    try std.testing.expectEqual(@as(usize, 4), @sizeOf(WriteOnly(u32)));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(WriteOnly(u32)));

    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ReadWrite(u32)));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(ReadWrite(u32)));

    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ApbReadWrite(u32)));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(ApbReadWrite(u32)));
}
