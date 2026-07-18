//! Minimal pico-zdk example.
//!
//! Besides being the smallest firmware that builds for every target, this
//! exercises reset-time memory initialization so it is not vacuous to inspect:
//!
//!   - `initialized` has a nonzero initializer, so it lands in `.data`, which
//!     the runtime copies from its flash load address into SRAM at boot.
//!   - `zeroed` is zero-initialized, so it lands in `.bss`, which the runtime
//!     clears at boot.
//!
//! Both are touched through `volatile` pointers so `ReleaseSmall` keeps their
//! storage instead of optimizing the globals away and collapsing the segments.

/// Nonzero initializer -> `.data`; proves the flash->SRAM copy path exists.
var initialized: u32 = 0x1234_5678;

/// Zero initializer -> `.bss`; proves the zero-clear path exists.
var zeroed: u32 = 0;

/// Application entry point called after runtime initialization.
pub fn main() void {
    const initialized_ptr: *volatile u32 = &initialized;
    const zeroed_ptr: *volatile u32 = &zeroed;
    // Volatile round-trips keep the globals in .data/.bss and stop the
    // optimizer from constant-folding them into immediates.
    initialized_ptr.* = initialized_ptr.* +% 1;
    zeroed_ptr.* = zeroed_ptr.* +% 1;
}
