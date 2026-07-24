//! Private intake of the generated `zdk_config` build options.
//!
//! The sole source-level importer of `zdk_config`: the library and runtime
//! receive this module and read the resolved axes from here.

const zdk_config = @import("zdk_config");

/// PCB the firmware runs on. Owns wiring facts (LED pin).
pub const board = zdk_config.board;

/// SoC mounted on that PCB. Owns register layouts and chip capabilities.
pub const chip = zdk_config.chip;

/// Package used on selected board.
pub const package = zdk_config.package;

/// CPU core the firmware boots on. Runtime startup selection reads this axis.
pub const core = zdk_config.core;
