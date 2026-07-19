const std = @import("std");
const pico_zdk = @import("renamed_zdk");

pub fn build(b: *std.Build) void {
    const pico = pico_zdk.Sdk.init(b, .{ .board = .pico });
    const pico2_riscv = pico_zdk.Sdk.init(b, .{
        .board = .pico2,
        .arch = .riscv,
    });

    pico.addFirmware(.{
        .name = "consumer-pico",
        .root_source_file = b.path("main.zig"),
    }).install();
    pico2_riscv.addFirmware(.{
        .name = "consumer-pico2-riscv",
        .root_source_file = b.path("main.zig"),
    }).install();
}
