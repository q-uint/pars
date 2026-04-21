//! Barrel module for the analysis passes. Exists so the test block
//! below can pull every sub-module into the test binary explicitly;
//! `refAllDecls` in root.zig doesn't recurse into nested struct
//! namespaces, and transitive imports from the compiler are a fragile
//! foundation (tests would silently disappear if an import were ever
//! dropped).

pub const first = @import("analysis/first.zig");
pub const grammar = @import("analysis/grammar.zig");

test {
    _ = first;
    _ = grammar;
}
