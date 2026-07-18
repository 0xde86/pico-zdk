//! Shared runtime entry: initialize memory, run the application, and keep the
//! core parked if the application ever returns.
//!
//! Both the Cortex-M and Hazard3 startup paths finish their arch-specific
//! register setup and then hand off here, so the "init memory, call main"
//!
//! The linker stores initialized `.data` at a flash load address but expects it
//! at its RAM virtual address, and reserves `.bss` without initializing it.
//! Segment bounds come from symbols defined by the `.ld` linker scripts.

const app = @import("app");

/// Initializes reset-time memory and enters the application's `main`.
///
/// The application exports `pub fn main()` returning either `noreturn` (it
/// keeps control forever) or `void` (it is allowed to return). Nothing follows
/// the program on a bare-metal core, so a `void` main that returns drops into a
/// low-power idle loop rather than executing off the end of the world.
pub inline fn entry() noreturn {
    memory_init();

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

extern var __data_load_start: u8;
extern var __data_start: u8;
extern var __data_end: u8;
extern var __bss_start: u8;
extern var __bss_end: u8;

/// Copies initialized `.data` from its flash load address into RAM and clears
/// `.bss`. Call once, before any code that reads or writes static storage.
inline fn memory_init() void {
    copyData();
    zeroBss();
}

inline fn copyData() void {
    var source: [*]const u8 = @ptrCast(&__data_load_start);
    var destination: [*]u8 = @ptrCast(&__data_start);
    const end = @intFromPtr(&__data_end);

    while (@intFromPtr(destination) < end) {
        destination[0] = source[0];
        source += 1;
        destination += 1;
    }
}

inline fn zeroBss() void {
    var destination: [*]u8 = @ptrCast(&__bss_start);
    const end = @intFromPtr(&__bss_end);

    while (@intFromPtr(destination) < end) {
        destination[0] = 0;
        destination += 1;
    }
}

/// Parks the core in a low-power wait loop. `wfi` ("wait for interrupt") is a
/// valid mnemonic on both Cortex-M and Hazard3.
inline fn idle() noreturn {
    while (true) asm volatile ("wfi");
}
