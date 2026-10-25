//! A lazy DFA over regex.zig's programs: does a line contain a match? One
//! table lookup per byte, where the Pike VM steps every live thread.
//!
//! A state is the set of VM threads alive at a position (the pcs of their
//! `set` and `eol` instructions), and is built the first time a transition
//! needs it. Every transition also starts a new thread at pc 0, so a state
//! answers for matches starting anywhere before it. A thread reaching
//! `match` ends the search: the line matches, whatever the other threads
//! would do, so all such states are one, `found`. No threads at all is
//! `dead`: the rest of the line can't match. `bol` holds only in the start
//! state; `eol` threads wait in a state until the line ends, when `eol` on
//! the state says whether any of them reaches `match`.
//!
//! Bytes are grouped into classes that every `set` treats alike, so a row
//! of the table has one entry per class. '\n' is a class of its own, which
//! lets `findLines` run over a whole buffer: '\n' ends a line (`found_eol`
//! if it matched there) and goes back to the start state.
//!
//! The cache of states is bounded (`max_cache` bytes per thread) and
//! cleared when full. If it keeps filling up after only a few bytes per
//! state, the pattern is one a DFA is bad at (`[a-z]{50}x` has a state per
//! combination of thread positions), and the DFA gives up for good:
//! `failed` is set and the caller uses the VM (or PCRE2) instead.
//!
//! `\b` is not supported (`init` returns null): ffs's `\b` looks at whole
//! UTF-8 characters, which one byte of lookbehind can't decide.

const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("regex.zig");
const match = @import("match.zig");
const Inst = regex.Inst;

// Transition targets from `special` up are not table rows.
const unknown: u32 = 0xffff_ffff; // not computed yet
const found: u32 = 0xffff_fffe; // a thread matched: the line matches
const found_eol: u32 = 0xffff_fffd; // the line that just ended ('\n') matched at its end
const dead: u32 = 0xffff_fffc; // no thread left: the rest of the line can't match
const special: u32 = dead;

// Ends the start state's key; no pc is this large.
const bol_mark: u32 = 0xffff_ffff;

/// Bytes of states and transitions one `Dfa` may cache.
const max_cache = 2 << 20;

pub const Dfa = struct {
    gpa: Allocator,
    prog: []const Inst,
    classes: [256]u8, // byte -> class
    reps: [256]u8, // class -> a byte in it
    n_classes: u32,
    nl: u8, // the class of '\n'

    // The cache. A state's id is its row's offset in `table` (index times
    // n_classes), so a transition is table[s + class].
    arena: std.heap.ArenaAllocator, // state keys and pcs
    table: std.ArrayList(u32) = .empty,
    eol: std.ArrayList(bool) = .empty, // by state index: matches at the line's end
    pcs: std.ArrayList([]const u32) = .empty, // by state index
    map: std.StringHashMapUnmanaged(u32) = .empty, // pcs (as bytes) -> id
    used: usize = 0, // bytes cached
    start: u32 = unknown, // the state at a line start, or found/dead

    // Scratch.
    seen: []u32, // seen[pc] == gen: pc already followed in this closure
    gen: u32 = 0,
    stack: std.ArrayList(u32) = .empty,
    seeds: std.ArrayList(u32) = .empty,
    buf: std.ArrayList(u32) = .empty,
    tmp: std.ArrayList(u32) = .empty,

    searched: usize = 0, // bytes searched since the cache was last cleared
    clears: usize = 0,
    /// The DFA gave up (or ran out of memory); don't call it again.
    failed: bool = false,
    /// After `findLines` fails with `error.GaveUp`: the line start to go on
    /// from, and its line number.
    resume_pos: usize = 0,
    resume_line: usize = 0,

    pub fn init(gpa: Allocator, prog: []const Inst) !?Dfa {
        for (prog) |inst| if (inst == .word_boundary) return null;
        var d: Dfa = .{
            .gpa = gpa,
            .prog = prog,
            .classes = undefined,
            .reps = undefined,
            .n_classes = 0,
            .nl = 0,
            .arena = .init(gpa),
            .seen = try gpa.alloc(u32, prog.len),
        };
        errdefer d.deinit();
        @memset(d.seen, 0);
        try d.computeClasses();
        d.start = try d.stateFor(&.{0}, true);
        return d;
    }

    pub fn deinit(d: *Dfa) void {
        d.arena.deinit();
        d.table.deinit(d.gpa);
        d.eol.deinit(d.gpa);
        d.pcs.deinit(d.gpa);
        d.map.deinit(d.gpa);
        d.gpa.free(d.seen);
        d.stack.deinit(d.gpa);
        d.seeds.deinit(d.gpa);
        d.buf.deinit(d.gpa);
        d.tmp.deinit(d.gpa);
    }

    // Splits the bytes into classes: two bytes share one when every `set`
    // in the program has both or neither. '\n' starts in a class of its own.
    fn computeClasses(d: *Dfa) !void {
        var cls: [256]u16 = @splat(0);
        cls['\n'] = 1;
        var done: std.AutoHashMapUnmanaged(u256, void) = .empty;
        defer done.deinit(d.gpa);
        for (d.prog) |inst| {
            if (inst != .set) continue;
            if ((try done.getOrPut(d.gpa, inst.set.mask)).found_existing) continue;
            var remap: [512]u16 = @splat(0xffff);
            var n: u16 = 0;
            for (&cls, 0..) |*c, b| {
                const key = c.* * 2 + @intFromBool(inst.set.isSet(b));
                if (remap[key] == 0xffff) {
                    remap[key] = n;
                    n += 1;
                }
                c.* = remap[key];
            }
        }
        var n: u32 = 0;
        for (cls) |c| n = @max(n, c + 1);
        for (cls, 0..) |c, b| {
            d.classes[b] = @intCast(c);
            d.reps[c] = @intCast(b);
        }
        d.n_classes = n;
        d.nl = d.classes['\n'];
    }

    /// Does `line` (no '\n') contain a match? Null if the DFA gave up.
    pub fn isMatch(d: *Dfa, line: []const u8) ?bool {
        if (d.failed) return null;
        d.searched += line.len;
        var s = d.start;
        var i: usize = 0;
        while (true) {
            if (s >= special) return s == found;
            if (i == line.len) return d.eol.items[s / d.n_classes];
            const c = d.classes[line[i]];
            var t = d.table.items[s + c];
            if (t == unknown) t = d.step(s, c) catch {
                d.failed = true;
                return null;
            };
            s = t;
            i += 1;
        }
    }

    /// `regex.findLines` for the whole of `data`: the DFA runs straight
    /// through it, '\n' included. On `error.GaveUp`, the lines from
    /// `resume_pos` on (line number `resume_line`) are still to search.
    pub fn findLines(d: *Dfa, data: []const u8, first_line: usize, sink: anytype) !usize {
        var line = first_line; // the line number of data[counted], a line start
        var counted: usize = 0;
        var i: usize = 0;
        var s = d.start;
        d.searched += data.len;
        while (true) {
            if (s >= special) switch (s) {
                found => {
                    // The line holding the byte just read, or starting at i.
                    const pos = if (i > 0 and data[i - 1] != '\n') i - 1 else i;
                    if (pos >= data.len) break; // no line starts at the end
                    line += std.mem.countScalar(u8, data[counted..pos], '\n');
                    const end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
                    try sink.onLine(match.Match{ .line = line, .data = data, .pos = pos, .end = end });
                    if (end == data.len) return line;
                    line += 1;
                    counted = end + 1;
                    i = end + 1;
                    s = d.start;
                    continue;
                },
                found_eol => {
                    const nl = i - 1;
                    line += std.mem.countScalar(u8, data[counted..nl], '\n');
                    try sink.onLine(match.Match{ .line = line, .data = data, .pos = nl, .end = nl });
                    line += 1;
                    counted = i;
                    s = d.start;
                    continue;
                },
                dead => {
                    const nl = std.mem.indexOfScalarPos(u8, data, i, '\n') orelse break;
                    i = nl + 1;
                    s = d.start;
                    continue;
                },
                else => unreachable,
            };
            if (i == data.len) {
                // The last line has no '\n': does it match at its end?
                if (i > 0 and data[i - 1] != '\n' and d.eol.items[s / d.n_classes]) {
                    line += std.mem.countScalar(u8, data[counted .. i - 1], '\n');
                    try sink.onLine(match.Match{ .line = line, .data = data, .pos = i - 1, .end = i });
                    return line;
                }
                break;
            }
            const c = d.classes[data[i]];
            var t = d.table.items[s + c];
            if (t == unknown) t = d.step(s, c) catch {
                d.failed = true;
                const ls = if (std.mem.findScalarLast(u8, data[counted..i], '\n')) |k| counted + k + 1 else counted;
                d.resume_pos = ls;
                d.resume_line = line + std.mem.countScalar(u8, data[counted..ls], '\n');
                return error.GaveUp;
            };
            s = t;
            i += 1;
        }
        return line + std.mem.countScalar(u8, data[counted..], '\n');
    }

    // The transition from state `s` on class `c`, computed and cached.
    fn step(d: *Dfa, s: u32, c: u8) error{ OutOfMemory, GaveUp }!u32 {
        const clears = d.clears;
        const t = if (c == d.nl) (if (d.eol.items[s / d.n_classes]) found_eol else d.start) else blk: {
            const b = d.reps[c];
            d.seeds.clearRetainingCapacity();
            for (d.pcs.items[s / d.n_classes]) |pc| {
                if (d.prog[pc] == .set and d.prog[pc].set.isSet(b)) try d.seeds.append(d.gpa, pc + 1);
            }
            try d.seeds.append(d.gpa, 0); // a match may start at every position
            break :blk try d.stateFor(d.seeds.items, false);
        };
        // A clear on the way made `s` meaningless; `t` is in the new cache.
        if (d.clears == clears) d.table.items[s + c] = t;
        return t;
    }

    // The state for the threads at `seeds` and everything they reach
    // without reading a byte.
    fn stateFor(d: *Dfa, seeds: []const u32, at_bol: bool) error{ OutOfMemory, GaveUp }!u32 {
        d.buf.clearRetainingCapacity();
        if (try d.closure(seeds, at_bol, false, &d.buf)) return found;
        if (d.buf.items.len == 0) return dead;
        std.mem.sortUnstable(u32, d.buf.items, {}, std.sort.asc(u32));
        const n_pcs = d.buf.items.len;
        // The start state answers `eol` for a line start, so it can't
        // share an entry with a state that has the same threads elsewhere.
        if (at_bol) try d.buf.append(d.gpa, bol_mark);
        const key = std.mem.sliceAsBytes(d.buf.items);
        if (d.map.get(key)) |id| return id;

        const cost = 2 * key.len + d.n_classes * @sizeOf(u32) + 64;
        if (d.used + cost > max_cache) try d.clear();

        // At the line's end, `eol` threads go on: do any of them match?
        d.seeds.clearRetainingCapacity(); // `seeds` may be this list: done with it
        for (d.buf.items[0..n_pcs]) |pc| if (d.prog[pc] == .eol) try d.seeds.append(d.gpa, pc + 1);
        d.tmp.clearRetainingCapacity();
        const eol = d.seeds.items.len > 0 and try d.closure(d.seeds.items, at_bol, true, &d.tmp);

        const a = d.arena.allocator();
        const stored = try a.dupe(u32, d.buf.items);
        const id: u32 = @intCast(d.table.items.len);
        try d.table.appendNTimes(d.gpa, unknown, d.n_classes);
        try d.eol.append(d.gpa, eol);
        try d.pcs.append(d.gpa, stored[0..n_pcs]);
        try d.map.put(d.gpa, std.mem.sliceAsBytes(stored), id);
        d.used += cost;
        if (d.start == unknown) d.start = try d.stateFor(&.{0}, true);
        return id;
    }

    // Empties the cache, or gives up if it fills too fast to be worth it.
    fn clear(d: *Dfa) error{GaveUp}!void {
        if (d.clears >= 3 and d.searched < 10 * d.eol.items.len) return error.GaveUp;
        d.clears += 1;
        d.searched = 0;
        d.table.clearRetainingCapacity();
        d.eol.clearRetainingCapacity();
        d.pcs.clearRetainingCapacity();
        d.map.clearRetainingCapacity();
        _ = d.arena.reset(.retain_capacity);
        d.used = 0;
        d.start = unknown;
    }

    // Follows `jmp`, `split` and the assertions that hold from `seeds`,
    // adding the `set` (and, before the line's end, `eol`) pcs reached to
    // `out`. Returns true on reaching `match`.
    fn closure(d: *Dfa, seeds: []const u32, at_bol: bool, at_eol: bool, out: *std.ArrayList(u32)) !bool {
        d.gen +%= 1;
        if (d.gen == 0) {
            @memset(d.seen, 0);
            d.gen = 1;
        }
        d.stack.clearRetainingCapacity();
        try d.stack.appendSlice(d.gpa, seeds);
        while (d.stack.pop()) |pc| {
            if (d.seen[pc] == d.gen) continue;
            d.seen[pc] = d.gen;
            switch (d.prog[pc]) {
                .match => return true,
                .set => try out.append(d.gpa, pc),
                .jmp => |t| try d.stack.append(d.gpa, t),
                .split => |t| try d.stack.appendSlice(d.gpa, &.{ t[1], t[0] }),
                .bol => if (at_bol) try d.stack.append(d.gpa, pc + 1),
                .eol => if (at_eol) try d.stack.append(d.gpa, pc + 1) else try out.append(d.gpa, pc),
                .word_boundary => unreachable,
            }
        }
        return false;
    }
};
