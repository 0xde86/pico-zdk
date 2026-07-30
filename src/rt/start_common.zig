//! Shared runtime entry: initialize memory, apply the selected startup policy,
//! run the application, and keep the core parked if it ever returns.
//!
//! Both the Cortex-M and Hazard3 startup paths finish their arch-specific
//! register setup and then hand off here, keeping the common lifecycle in one
//! place.
//!
//! The linker stores initialized `.data` at a flash load address but expects it
//! at its RAM virtual address, and reserves `.bss` without initializing it.
//! Segment bounds come from symbols defined by the `.ld` linker scripts.

const app = @import("app");
const zdk = @import("pico_zdk");
const init = @import("init.zig");

/// Program options in force, read from the firmware root module.
pub const options: zdk.Options = if (@hasDecl(app, "zdk_options")) app.zdk_options else .{};

/// Initializes reset-time memory and enters the application's `main`.
///
/// The application exports `pub fn main()` returning either `noreturn` (it
/// keeps control forever) or `void` (it is allowed to return). Nothing follows
/// the program on a bare-metal core, so a `void` main that returns drops into a
/// low-power idle loop rather than executing off the end of the world.
pub inline fn entry() noreturn {
    memoryInit();
    startupInit();

    const Return = @typeInfo(@TypeOf(app.main)).@"fn".return_type.?;
    if (Return == noreturn) {
        // `main` never returns; control stays inside it.
        app.main();
    } else if (Return == void) {
        // `main` may return; idle the core afterwards instead of running past it.
        app.main();
        idle();
    } else {
        @compileError("pico-zdk: `main` must return `void` or `noreturn`, but it returns `" ++ @typeName(Return) ++ "`");
    }
}

/// Applies `options.startup` after static storage exists and before `main`.
///
/// The chain runs after `memoryInit` because it records the clock frequencies it
/// establishes in static storage, which `.bss` initialization would otherwise
/// wipe out afterwards.
inline fn startupInit() void {
    switch (options.startup) {
        .spec => init.spec(),
        // Nothing to do by construction: reset already established this state.
        .reset_state => {},
    }
}

extern var __data_load_start: u8;
extern var __data_start: u8;
extern var __data_end: u8;
extern var __bss_start: u8;
extern var __bss_end: u8;

/// Copies initialized `.data` from its flash load address into RAM and clears
/// `.bss`. Call once, before any code that reads or writes static storage.
///
/// Runtime safety is off because its panic machinery cannot run before `.bss`
/// exists. The linker scripts guarantee that each end symbol follows its start
/// symbol and that both ranges name writable RAM.
inline fn memoryInit() void {
    @setRuntimeSafety(false);

    const data: [*]u8 = @ptrCast(&__data_start);
    const data_src: [*]const u8 = @ptrCast(&__data_load_start);
    const data_len = @intFromPtr(&__data_end) - @intFromPtr(&__data_start);
    @memcpy(data[0..data_len], data_src[0..data_len]);

    const bss: [*]u8 = @ptrCast(&__bss_start);
    const bss_len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    @memset(bss[0..bss_len], 0);
}

/// Parks the core in a low-power wait loop. `wfi` ("wait for interrupt") is a
/// valid mnemonic on both Cortex-M and Hazard3.
inline fn idle() noreturn {
    while (true) asm volatile ("wfi");
}
