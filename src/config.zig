//! Private intake of the generated `zdk_config` build options.
//!
//! The library's sole importer of `zdk_config`: everything else reads the
//! resolved axes from here.

const zdk_config = @import("zdk_config");

/// PCB the firmware runs on. Owns wiring facts (LED pin).
pub const board = zdk_config.board;

/// SoC mounted on that PCB. Owns register layouts and chip capabilities.
pub const chip = zdk_config.chip;

/// CPU core the firmware boots on. The runtime module reads this axis from
/// its own `zdk_config` import; it is mirrored here for completeness.
pub const core = zdk_config.core;
