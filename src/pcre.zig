//! Optional PCRE2 backend, built with `zig build -Dpcre2=true` (links the
//! system's libpcre2-8). It does not change which lines match: patterns are
//! still parsed and checked by regex.zig, and PCRE2 only replaces the Pike
//! VM where it is faster, with its JIT:
//!
//!   - checking the candidate lines the SIMD prefilter hands over;
//!   - finding matches in a whole buffer when a regex has no literal to
//!     prefilter with (`searchLines`).
//!
//! Without the option, `enabled` is false and nothing here is compiled in.

const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.pcre2;

const Code = opaque {};
const MatchData = opaque {};

extern fn pcre2_compile_8(pattern: [*]const u8, length: usize, options: u32, errorcode: *c_int, erroroffset: *usize, ccontext: ?*anyopaque) ?*Code;
extern fn pcre2_jit_compile_8(code: *Code, options: u32) c_int;
extern fn pcre2_code_free_8(code: *Code) void;
extern fn pcre2_match_data_create_from_pattern_8(code: *const Code, gcontext: ?*anyopaque) ?*MatchData;
extern fn pcre2_match_data_free_8(md: *MatchData) void;
extern fn pcre2_jit_match_8(code: *const Code, subject: [*]const u8, length: usize, startoffset: usize, options: u32, md: *MatchData, mcontext: ?*anyopaque) c_int;
extern fn pcre2_get_ovector_pointer_8(md: *MatchData) [*]usize;

const CASELESS: u32 = 0x00000008;
const MULTILINE: u32 = 0x00000400;
const JIT_COMPLETE: u32 = 0x00000001;
const ERROR_NOMATCH: c_int = -1;

pub const Span = struct { start: usize, end: usize };

/// A compiled, JIT-compiled pattern; shared by all threads.
pub const Pattern = struct {
    code: *Code,

    /// Null if PCRE2 can't take the pattern or has no JIT here; the caller
    /// then keeps using the Pike VM. MULTILINE: `^` and `$` match at line
    /// ends inside a buffer, and at the ends of a single line.
    pub fn compile(src: []const u8, ignore_case: bool) ?Pattern {
        var err: c_int = 0;
        var offset: usize = 0;
        const options: u32 = MULTILINE | (if (ignore_case) CASELESS else 0);
        const code = pcre2_compile_8(src.ptr, src.len, options, &err, &offset, null) orelse return null;
        if (pcre2_jit_compile_8(code, JIT_COMPLETE) != 0) {
            pcre2_code_free_8(code);
            return null;
        }
        return .{ .code = code };
    }

    pub fn deinit(p: Pattern) void {
        pcre2_code_free_8(p.code);
    }
};

/// Per-thread match state.
pub const Matcher = struct {
    md: *MatchData,

    pub fn init(p: Pattern) !Matcher {
        return .{ .md = pcre2_match_data_create_from_pattern_8(p.code, null) orelse return error.OutOfMemory };
    }

    pub fn deinit(m: Matcher) void {
        pcre2_match_data_free_8(m.md);
    }

    /// The leftmost-first match in `subject` at or after `from`, or
    /// `error.Limit` if PCRE2 gave up before knowing (its match limit, or
    /// the JIT stack on a long subject): that is not "no match".
    pub fn find(m: Matcher, p: Pattern, subject: []const u8, from: usize) error{Limit}!?Span {
        // A zero-length subject still needs a valid pointer.
        const ptr: [*]const u8 = if (subject.len > 0) subject.ptr else "";
        const rc = pcre2_jit_match_8(p.code, ptr, subject.len, from, 0, m.md, null);
        if (rc == ERROR_NOMATCH) return null;
        if (rc < 0) return error.Limit;
        const ov = pcre2_get_ovector_pointer_8(m.md);
        return .{ .start = ov[0], .end = ov[1] };
    }
};
