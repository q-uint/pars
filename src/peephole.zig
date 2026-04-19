//! Peephole optimizer.
//!
//! Passes come in two flavours, picked per-pass based on what
//! information each needs to fire safely:
//!
//!   - **Emit-time** passes hook into the compiler at the moment a
//!     specific construct has just been emitted. The region is
//!     locally bounded, no outside code references into it yet, and
//!     no jump-target fixup is needed.
//!
//!   - **Post-emit** passes run once a whole rule body or top-level
//!     chunk is finalized. They need the full chunk in hand to find
//!     every jump target and rewrite offsets that straddle a
//!     rewritten region, but the payoff is that they see across
//!     construct boundaries (e.g. merges introduced by quantifier
//!     duplication).
//!
//! Each pass lives in its own file under peephole/ with its doc
//! comment, before/after example, and unit tests. This module
//! re-exports the public entry points and pulls the pass files into
//! the test graph.
//!
//! Current passes:
//!   - fuseCharsetChoice (emit-time): `A / B` where both arms are
//!     single-byte matchers collapses to one op_match_charset over
//!     (A ∪ B). Called from Compiler.choiceOp right after both arms
//!     and their scaffolding are emitted.
//!   - mergeAdjacentLiterals (post-emit): runs of mergeable literal
//!     instructions collapse to one op_match_string over the
//!     concatenation, with jump offsets that straddle the merged
//!     region adjusted for the shrinkage. Called after every chunk
//!     finishes compiling.

const fuse_charset_choice = @import("peephole/fuse_charset_choice.zig");
const merge_adjacent_literals = @import("peephole/merge_adjacent_literals.zig");

pub const emit_time = struct {
    pub const fuseCharsetChoice = fuse_charset_choice.fuseCharsetChoice;
};

pub const post_emit = struct {
    pub const mergeAdjacentLiterals = merge_adjacent_literals.mergeAdjacentLiterals;
};

/// Per-pass on/off switches consulted by the compiler. Default is
/// "all on" — production compiles get every optimization. Tests that
/// assert pre-peephole bytecode shape construct a Compiler with the
/// relevant pass turned off so the assertions stay grounded in the
/// raw bytecode rather than the optimized result.
///
/// Every pass exported above must have a matching boolean field
/// here; the compiler reads these flags before invoking each pass.
/// `Config.off` flips all of them at once for tests that want to
/// see the raw, un-rewritten bytecode.
pub const Config = struct {
    fuse_charset_choice: bool = true,
    merge_adjacent_literals: bool = true,

    pub const off: Config = .{
        .fuse_charset_choice = false,
        .merge_adjacent_literals = false,
    };
};

test {
    _ = fuse_charset_choice;
    _ = merge_adjacent_literals;
}
