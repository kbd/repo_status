const std = @import("std");
const stdout = std.io.getStdOut().writer();
const dp = std.debug.print;
const os = std.os;
const Allocator = std.mem.Allocator;
const proc = std.ChildProcess;
const eql = std.mem.eql;
const len = std.mem.len;
const assert = std.debug.assert;
const expect = std.testing.expect;
const ArrayList = std.ArrayList;

// this compile-errors on 0.7.1-0.8.0
// https://github.com/ziglang/zig/issues/6682
// pub const io_mode = .evented;

const Str = []const u8;

const Status = enum {
    ahead,
    behind,
    staged,
    added,
    modified,
    removed,
    stashed,
    untracked,
    conflicted,
    renamed,
    unknown,
};
const STATUS_LEN = 11; // hand-counted. Waiting for enum arrays.

const GitStatus = struct {
    state: Str,
    branch: Str,
    status: [STATUS_LEN]u32,
    stash: std.StringHashMap(u32),
};

const Shell = enum {
    zsh,
    bash,
    unknown,
};

const AheadBehind = struct {
    ahead: u32 = 0,
    behind: u32 = 0,
};

pub const Escapes = struct {
    o: [:0]const u8 = undefined,
    c: [:0]const u8 = undefined,

    pub fn init(open: [:0]const u8, close: [:0]const u8) Escapes {
        return Escapes{ .o = open, .c = close };
    }
};

pub const C = .{
    .reset = "\x1b[00m",
    .bold = "\x1b[01m",
    .italic = "\x1b[03m",
    .underline = "\x1b[04m",
    .reverse = "\x1b[07m",
    .italic_off = "\x1b[23m",
    .underline_off = "\x1b[24m",
    .reverse_off = "\x1b[27m",

    .black = "\x1b[30m",
    .red = "\x1b[31m",
    .green = "\x1b[32m",
    .yellow = "\x1b[33m",
    .blue = "\x1b[34m",
    .magenta = "\x1b[35m",
    .cyan = "\x1b[36m",
    .white = "\x1b[37m",
    .default = "\x1b[39m",
};

pub var A: Allocator = undefined;
pub var E: Escapes = undefined;
pub var CWD: Str = undefined;

fn concatStringArray(lists: []const []Str) ![]Str {
    return try std.mem.concat(A, Str, lists);
}

fn gitCmd(args: []Str, workingdir: Str) !proc.ExecResult {
    var gitcmd = [_]Str{ "git", "-C", workingdir };
    var cmd_parts = [_][]Str{ &gitcmd, args };
    var cmd = try concatStringArray(&cmd_parts);
    return try run(cmd);
}

fn run(argv: []const Str) !proc.ExecResult {
    return try proc.exec(.{
        .allocator = A,
        .argv = argv,
        .max_output_bytes = std.math.maxInt(u32),
    });
}

fn getState(dir: Str) !Str {
    // Return a code for the current repo state.
    //
    // Possible states:
    //     R - rebase
    //     M - merge
    //     C - cherry-pick
    //     B - bisect
    //     V - revert
    //
    // The code returned will indicate multiple states (if that's possible?)
    // or the empty string if the repo is in a normal state.

    // Unfortunately there's no porcelain to check for various git states.
    // Determining state is done by checking for the existence of files within
    // the git repository. Reference for possible checks:
    // https://github.com/git/git/blob/master/contrib/completion/git-prompt.sh
    const checks = .{
        .{ .filename = "rebase-merge", .code = "R" },
        .{ .filename = "rebase-apply", .code = "R" },
        .{ .filename = "MERGE_HEAD", .code = "M" },
        .{ .filename = "CHERRY_PICK_HEAD", .code = "C" },
        .{ .filename = "BISECT_LOG", .code = "B" },
        .{ .filename = "REVERT_HEAD", .code = "V" },
    };

    var cmd = [_]Str{ "rev-parse", "--git-dir" };
    var result = try gitCmd(&cmd, dir);
    if (result.term.Exited != 0)
        return error.GetGitDirFailed;

    var git_dir = strip(result.stdout);

    var state_set = std.BufSet.init(A);
    inline for (checks) |check| {
        var path = try std.fs.path.join(A, &[_]Str{ git_dir, check.filename });
        if (exists(path))
            try state_set.insert(check.code);
    }

    var list = std.ArrayList(Str).init(A);
    var it = state_set.iterator();
    while (it.next()) |entry| {
        try list.append(entry.*);
    }
    return std.mem.join(A, "", list.items);
    // sort later, not a good use of time
    // std.sort.sort(u8, state_set)
}

fn access(pth: Str, flags: std.fs.File.OpenFlags) !void {
    try std.fs.cwd().access(pth, flags);
}

fn exists(pth: Str) bool {
    access(pth, .{}) catch return false;
    return true;
}

fn strip(s: Str) Str {
    return std.mem.trim(u8, s, " \t\n");
}

fn getBranch(dir: Str) !Str {
    var cmd1 = [_]Str{ "symbolic-ref", "HEAD", "--short" };
    var result = try gitCmd(&cmd1, dir);
    if (result.term.Exited == 0)
        return strip(result.stdout);

    var cmd2 = [_]Str{ "describe", "--all", "--contains", "--always", "HEAD" };
    result = try gitCmd(&cmd2, dir);
    return strip(result.stdout);
}

fn getRepoStashCounts(dir: Str) !std.StringHashMap(u32) {
    var cmd = [_]Str{ "stash", "list", "-z" };
    var result = try gitCmd(&cmd, dir);
    if (result.term.Exited != 0)
        std.log.err("Couldn't get stash list ({})", .{result.term.Exited});

    var lines = slurpSplit(&result.stdout, "\x00");
    return parseRepoStash(lines);
}

fn getBranchNameFromStashLine(line: Str) Str {
    var parts = slurpSplit(&line, ":");
    if (parts.len <= 1)
        return "";

    var part = parts[1];
    if (std.mem.eql(u8, part, " autostash"))
        return "-autostash";

    var wordstart = std.mem.lastIndexOf(u8, part, " ") orelse 0;
    var result = part[wordstart + 1 ..];

    return result;
}

test "get branch name from status line" {
    A = std.testing.allocator;
    var line: Str = "stash@{1}: WIP on master: 8dbbdc4 commit one";
    var result = getBranchNameFromStashLine(line);
    try expect(std.mem.eql(u8, result, "master"));

    line = "stash@{1}: autostash";
    result = getBranchNameFromStashLine(line);
    try expect(std.mem.eql(u8, result, "-autostash"));
}

fn parseRepoStash(stashlines: []Str) !std.StringHashMap(u32) {
    // stash output looks like:
    // stash@{0}: On (no branch): push file to stash
    // stash@{1}: WIP on master: 8dbbdc4 commit one
    // stash@{2}: autostash
    //
    // https://www.git-scm.com/docs/git-stash//Documentation/git-stash.txt-listltoptionsgt
    var result = std.StringHashMap(u32).init(A);
    for (stashlines) |line| {
        var branch = getBranchNameFromStashLine(line);
        var entry = try result.getOrPutValue(branch, 0);
        entry.value_ptr.* += 1;
    }
    return result;
}

test "parse repo stash" {
    A = std.testing.allocator;
    var lines = [_]Str{
        "stash@{0}: On (no branch): push file to stash",
        "stash@{1}: WIP on master: 8dbbdc4 commit one",
        "stash@{2}: autostash",
    };
    var result = try parseRepoStash(&lines);
    var val = result.get("master") orelse 0;
    try expect(val == 1);
    val = result.get("-autostash") orelse 0;
    try expect(val == 1);
}

fn formatStashes(status: GitStatus) Str {
    // Return a Str like "1A" for one stash on current branch and one autostash
    // todo: also display count of all stashes?
    var branch_count = status.stash.get(status.branch) orelse 0;
    var autostash_count = status.stash.get("-autostash") orelse 0;

    var count = if (branch_count == 0) "" else intToStr(branch_count) catch "";
    var autostash = if (autostash_count > 0) "A" else "";
    var str = std.mem.concat(A, u8, &[_]Str{ count, autostash }) catch "";
    return str;
}

fn parseCode(statusCode: Str) Status {
    // see https://git-scm.com/docs/git-status//_short_format for meaning of codes
    if (eql(u8, statusCode, "??"))
        return Status.untracked;

    var index = statusCode[0];
    var worktree = statusCode[1];

    if (index == 'R') {
        return Status.renamed;
    } else if (index != ' ') {
        if (worktree != ' ') {
            return Status.conflicted;
        } else {
            return Status.staged;
        }
    }
    return switch (worktree) {
        'A' => Status.added,
        'M' => Status.modified,
        'D' => Status.removed,
        else => Status.unknown,
    };
}

test "parse codes" {
    var s: Status = parseCode(" M");
    assert(s == Status.modified);

    s = parseCode("??");
    assert(s == Status.untracked);
}

fn parseStatusLines(lines: []Str) [STATUS_LEN]u32 {
    var codes: [STATUS_LEN]u32 = [_]u32{0} ** STATUS_LEN;
    if (lines.len == 0)
        return codes;

    var skip = false;
    for (lines) |line| {
        if (skip) {
            skip = false;
            continue;
        }
        if (std.mem.eql(u8, strip(line), ""))
            continue;

        var code = line[0..2];
        var c = parseCode(code);
        if (c == Status.renamed) {
            // renamed files have two lines of status, skip the next line
            codes[@intFromEnum(Status.staged)] += 1;
            skip = true;
        } else {
            codes[@intFromEnum(c)] += 1;
        }
    }
    return codes;
}

test "parse lines" {
    var lines = [_]Str{
        " M repo_status.zig",
        " M todo.txt",
        "?? .gitignore",
        "?? repo_status",
        "?? test",
        "?? test.nim",
        "?? test.zig",
    };
    var codes = parseStatusLines(&lines);
    var i = @intFromEnum(Status.modified);
    assert(codes[i] == 2);
    assert(2 == 2);
}

fn parseAheadBehind(source: Str) AheadBehind {
    var result = AheadBehind{};

    var bracketPos = std.mem.indexOf(u8, source, "[") orelse return result;
    if (std.mem.indexOfPos(u8, source, bracketPos + 1, "ahead ")) |aheadPos|
        result.ahead = strToInt(source[aheadPos + 6 ..]);
    if (std.mem.indexOfPos(u8, source, bracketPos + 1, "behind ")) |behindPos|
        result.behind = strToInt(source[behindPos + 7 ..]);

    return result;
}

test "parse ahead/behind" {
    var source = "## master...origin/master [ahead 3, behind 2]";
    var result = parseAheadBehind(source);
    try expect(result.ahead == 3);
    try expect(result.behind == 2);

    var source2 = "## master...origin/master";
    result = parseAheadBehind(source2);
    try expect(result.ahead == 0);
    try expect(result.behind == 0);

    var source3 = "## master...origin/master [ahead 3]";
    result = parseAheadBehind(source3);
    try expect(result.ahead == 3);
    try expect(result.behind == 0);
}

fn strToInt(source: Str) u32 {
    // source should be a slice pointing to the right position in the string
    // find the integer at the start of 'source', return 0 if no digits found
    var it = std.mem.tokenize(u8, source, ", ]");
    var val = it.next() orelse return 0;
    return std.fmt.parseInt(u32, val, 10) catch return 0;
}

test "parse digits from string" {
    var str = "123]";
    var digit = strToInt(str);
    try expect(digit == 123);
}

fn intToStr(i: u32) !Str {
    var buffer = try A.create([10]u8);
    var stream = std.io.fixedBufferStream(buffer);
    try std.fmt.formatIntValue(i, "", .{}, stream.writer());
    return stream.getWritten();
}

test "test string to integer" {
    A = std.testing.allocator;
    try expect(std.mem.eql(u8, try intToStr(5), "5"));
    try expect(std.mem.eql(u8, try intToStr(9), "9"));
    try expect(std.mem.eql(u8, try intToStr(123), "123"));
}

fn slurpSplit(source: *const Str, delim: Str) []Str {
    var lines = std.mem.split(u8, source.*, delim);
    var finalLines = std.ArrayList(Str).init(A);
    // defer finalLines.deinit();
    while (lines.next()) |line| {
        var stripped_line = strip(line);
        if (std.mem.eql(u8, stripped_line, ""))
            continue;

        finalLines.append(line) catch |err| {
            dp("Error when appending: {}", .{err});
        };
    }
    return finalLines.toOwnedSlice() catch &[_]Str{};
}

test "slurp split" {
    var lines: Str =
        \\ abc
        \\ def
    ;
    var result = slurpSplit(&lines, "\n");
    try expect(std.mem.eql(u8, result[0], " abc"));
    try expect(std.mem.eql(u8, result[1], " def"));

    var str: Str = "a:b";
    result = slurpSplit(&str, ":");
    try expect(std.mem.eql(u8, result[0], "a"));
    try expect(std.mem.eql(u8, result[1], "b"));
}

// example git status output
// g s -zb | tr '\0' '\n'
// ## master...origin/master [ahead 1]
//  M repo_status.zig
//  M todo.txt
// ?? .gitignore
// ?? repo_status
// ?? test
// ?? test.nim
// ?? test.zig
fn parseStatus(status_txt: *Str) [STATUS_LEN]u32 {
    var slice = slurpSplit(status_txt, "\x00");
    var status = parseStatusLines(slice[1..]);
    var ahead_behind = parseAheadBehind(slice[0]);
    status[@intFromEnum(Status.ahead)] = ahead_behind.ahead;
    status[@intFromEnum(Status.behind)] = ahead_behind.behind;
    return status;
}

test "parse status" {
    var lines =
        \\## master...origin/master [ahead 1]
        \\ M repo_status.zig
        \\ M todo.txt
        \\?? .gitignore
        \\?? repo_status
        \\?? test
        \\?? test.nim
        \\?? test.zig
    ;
    A = std.testing.allocator;
    var buffer: [300]u8 = undefined;
    _ = std.mem.replace(u8, lines, "\n", "\x00", buffer[0..]);
    var x: Str = &buffer;
    var status = parseStatus(&x);
    try expect(status[@intFromEnum(Status.untracked)] == 5);
}

fn getStatus(dir: Str) ![STATUS_LEN]u32 {
    // get and parse status codes
    var cmd = [_]Str{ "status", "-zb" };
    var result = try gitCmd(&cmd, dir);
    if (result.term.Exited != 0)
        return error.GitStatusFailed;

    return parseStatus(&result.stdout);
}

pub fn isGitRepo(dir: Str) bool {
    var cmd = [_]Str{ "rev-parse", "--is-inside-work-tree" };
    var result = gitCmd(&cmd, dir) catch |err| {
        std.log.err("Couldn't read git repo at {s}. Err: {}", .{ dir, err });
        return false;
    };
    var out = strip(result.stdout);
    return result.term.Exited == 0 and !std.mem.eql(u8, out, "false");
}

fn styleWrite(esc: Escapes, color: Str, value: Str) !void {
    try stdout.print("{s}{s}{s}{s}{s}{s}{s}", .{
        esc.o, color, esc.c, value, esc.o, C.default, esc.c,
    });
}

pub fn writeStatusStr(esc: Escapes, status: GitStatus) !void {
    // o, c = e[shell].o.replace('{', '{{'), e[shell].c.replace('}', '}}')
    const format = .{
        // using arrays over tuples failed
        .{ .color = C.green, .token = @as(Str, "↑"), .status = Status.ahead },
        .{ .color = C.red, .token = @as(Str, "↓"), .status = Status.behind },
        .{ .color = C.green, .token = @as(Str, "●"), .status = Status.staged },
        .{ .color = C.yellow, .token = @as(Str, "+"), .status = Status.modified },
        .{ .color = C.red, .token = @as(Str, "-"), .status = Status.removed },
        .{ .color = C.cyan, .token = @as(Str, "…"), .status = Status.untracked },
        .{ .color = C.blue, .token = @as(Str, "⚑"), .status = Status.stashed },
        .{ .color = C.red, .token = @as(Str, "✖"), .status = Status.conflicted },
    };

    // print state
    if (!std.mem.eql(u8, status.state, "")) {
        try styleWrite(esc, C.magenta, status.state);
        try stdout.print(" ", .{});
    }

    // print branch
    try styleWrite(esc, C.yellow, status.branch);

    // print stats
    var printed_space = false;
    inline for (format) |f| {
        var str: Str = undefined;
        if (f.status == Status.stashed) {
            str = formatStashes(status);
        } else {
            var num = status.status[@intFromEnum(f.status)];
            str = if (num == 0) "" else try intToStr(num);
        }
        if (!std.mem.eql(u8, str, "")) {
            if (!printed_space) {
                try stdout.print(" ", .{});
                printed_space = true;
            }
            var strings = [_]Str{ f.token, str };
            var temp = try std.mem.concat(A, u8, &strings);
            try styleWrite(esc, f.color, temp);
        }
    }
}

pub fn getFullRepoStatus(dir: Str) !GitStatus {
    var branch = getBranch(dir);
    var status = getStatus(dir);
    var state = getState(dir);
    var stash = getRepoStashCounts(dir);
    return GitStatus{
        .state = try state,
        .branch = try branch,
        .status = try status,
        .stash = try stash,
    };
}

pub fn main() !u8 {
    // allocator setup
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    A = arena.allocator();

    var dir: Str = ".";
    var shellstr: Str = "";
    if (std.os.argv.len == 3)
        shellstr = std.mem.span(std.os.argv[1]);

    if (std.os.argv.len > 1)
        dir = std.mem.span(std.os.argv[std.os.argv.len - 1]);

    if (std.os.argv.len > 3) {
        dp("Usage: repo_status [zsh|bash] [directory]\n", .{});
        return 3;
    }

    // get the specified shell and initialize escape codes
    var shell = Shell.unknown;
    if (std.mem.eql(u8, shellstr, "zsh")) {
        shell = Shell.zsh;
    } else if (std.mem.eql(u8, shellstr, "bash")) {
        shell = Shell.bash;
    } else if (!std.mem.eql(u8, shellstr, "")) {
        dp("Unknown shell: '{s}'\n", .{shellstr});
        return 3;
    }

    switch (shell) {
        .zsh => {
            E = Escapes.init("%{", "%}");
        },
        .bash => {
            E = Escapes.init("\\[", "\\]");
        },
        else => {
            E = Escapes.init("", "");
        },
    }

    if (!isGitRepo(dir))
        return 2; // specific error code for 'not a repository'

    var status = try getFullRepoStatus(dir);
    try writeStatusStr(E, status);
    return 0;
}
