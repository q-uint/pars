const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;

pub const max_frames = 64;
pub const max_bt = 256;

pub const no_label: u32 = std.math.maxInt(u32);

/// Sentinel value for `CallFrame.seed_pos` meaning "no seed yet"
/// (equivalent to Warth's initial FAIL seed). A real seed can never
/// take this value because it is always a valid input position, which
/// is bounded by the input length and therefore well below maxInt.
pub const no_seed: usize = std.math.maxInt(usize);

pub const CallFrame = struct {
    // Caller's chunk and ip, restored on OP_RETURN so execution
    // resumes at the instruction after the OP_CALL.
    chunk: *Chunk,
    ip: usize,
    // Callee's chunk: the rule actually active in this frame. Kept
    // separate from `chunk` so left-recursion detection can compare
    // against the rule being executed, not the rule that made the
    // call. Comparing against the caller falsely flags right-
    // recursion through shared dispatch rules (e.g. primary → capture
    // → expr → primary, where the inner primary's call to capture
    // would match the outer capture's own outgoing call).
    callee: *Chunk,
    // Input position at which the callee was entered. Used to detect
    // left recursion: if the same rule is already active at the same
    // position, no input can ever be consumed and the parse would
    // loop forever.
    entry_pos: usize,
    // Constant-pool index of a label installed by op_cut_label in this
    // rule, or the no_label sentinel. Consulted by fail() when failure
    // propagates past every remaining backtrack frame: the innermost
    // active label becomes the runtime-error message.
    commit_label: u32,
    // True when the callee was declared `#[lr]` (ADR 010). Switches
    // the VM onto the seed-growing path: a recursive call at the same
    // position reads `seed_pos` instead of erroring, and op_return
    // iterates the body until growth stops.
    is_lr: bool,
    // Best match endpoint recorded for an `is_lr` frame across
    // seed-growing iterations. `no_seed` on entry and while the body's
    // first iteration is still running; set to the current `pos` when
    // the body reaches op_return, which advances subsequent recursive
    // calls by jumping `pos` to this value.
    seed_pos: usize,
};

/// Kind tag on backtrack frames so op_cut can recognize which frame is
/// an ordered-choice frame (the only kind a cut may commit) and skip
/// past frames pushed by quantifiers or lookaheads (ADR 008). `.longest`
/// is the marker frame pushed by op_longest_begin; it is never a
/// backtrack target and is always pushed with `committed = true` so
/// fail() walks past it without restoring state.
pub const FrameKind = enum(u8) { choice, quant, lookahead, longest };

pub const BacktrackFrame = struct {
    ip: usize,
    pos: usize,
    chunk: *Chunk,
    frame_count: usize,
    kind: FrameKind,
    // Set to true by op_cut on the innermost in-scope choice frame.
    // A committed frame stays on the stack so the matching op_commit
    // still pops it, but fail() treats it as absent when unwinding,
    // preventing backtracking into a committed alternative.
    committed: bool,
    // Best endpoint recorded across arms of a longest-match group.
    // Written by op_longest_step on the enclosing `.longest` frame and
    // read by op_longest_end. `no_seed` means no arm has matched yet;
    // any real position is well below maxInt so the sentinel cannot
    // collide with a genuine endpoint.
    best_pos: usize,
};
