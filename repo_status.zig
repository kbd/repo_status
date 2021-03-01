const std = @import("std");
const stdout = std.io.getStdOut().writer();
const print = stdout.print;
const dp = std.debug.print;
const os = std.os;
const Allocator = std.mem.Allocator;
const funcs = @import("funcs.zig");
const proc = std.ChildProcess;
const eql = std.mem.eql;
const len = std.mem.len;
const assert = std.debug.assert;
const expect = std.testing.expect;
const ArrayList = std.ArrayList;

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
    // state: Str,
    branch: Str,
    status: [STATUS_LEN]u32,
    // stash: Table[Str, int]
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
    .default = "\x1b[91m",

    .black = "\x1b[30m",
    .red = "\x1b[31m",
    .green = "\x1b[32m",
    .yellow = "\x1b[33m",
    .blue = "\x1b[34m",
    .magenta = "\x1b[35m",
    .cyan = "\x1b[36m",
    .white = "\x1b[37m",
};

pub var A: *Allocator = undefined;
pub var E: Escapes = undefined;
pub var CWD: Str = undefined;

fn concatStringArray(lists: []const []Str) ![]Str {
    return try std.mem.concat(A, Str, lists);
}

fn gitCmd(args: []Str, workingdir: Str) !proc.ExecResult {
    var gitcmd = [_]Str{"git", "-C", workingdir};
    var cmd_parts = [_][]Str{ &gitcmd, args };
    var cmd = try concatStringArray(&cmd_parts);
    return try run(cmd);
}

fn run(argv: []const Str) !proc.ExecResult {
    return try proc.exec(.{
        .allocator = A,
        .argv = argv,
    });
}

// fn getState(dir: Str) !Str {
//     // Return a code for the current repo state.
//     //
//     // Possible states:
//     //     R - rebase
//     //     M - merge
//     //     C - cherry-pick
//     //     B - bisect
//     //     V - revert
//     //
//     // The code returned will indicate multiple states (if that's possible?)
//     // or the empty Str if the repo is in a normal state.

//     // Unfortunately there's no porcelain to check for various git states.
//     // Determining state is done by checking for the existence of files within
//     // the git repository. Reference for possible checks:
//     // https://github.com/git/git/blob/master/contrib/completion/git-prompt.sh
//     var checks = {
//         "rebase-merge": 'R',
//         "rebase-apply": 'R',
//         "MERGE_HEAD": 'M',
//         "CHERRY_PICK_HEAD": 'C',
//         "BISECT_LOG": 'B',
//         "REVERT_HEAD": 'V',
//     }.toTable

//     var git_dir = getGitDir(dir)

//     var state_set: set[char]
//     for filename, status_code in checks:
//         var path = git_dir / filename
//         if path.fileExists or path.dirExists:
//             state_set.incl status_code

//     return join(state_set.toSeq.sorted, "")
//     return "";
// }

// fn formatStashes(status: GitStatus): Str =
//     //// Return a Str like 1A for one stash on current branch and one autostash
//     //// todo: also display count of all stashes?
//     // var total = sum(toSeq(status.stash.values))
//     var branch_count = status.stash.getOrDefault(status.branch)
//     var autostash = status.stash.getOrDefault("-autostash")

//     if branch_count > 0:
//         result &= $branch_count

//     if autostash > 0:
//         result &= 'A'


fn rstrip(s: Str) Str {
    return std.mem.trim(u8, s, " \n");
}

fn getBranch(dir: Str) !Str {
    var cmd1 = [_]Str{"symbolic-ref", "HEAD", "--short"};
    var result = try gitCmd(&cmd1, dir);
    if (result.term.Exited == 0)
        return rstrip(result.stdout);

    var cmd2 = [_]Str{"describe", "--all", "--contains", "--always", "HEAD"};
    result = try gitCmd(&cmd2, dir);
    return rstrip(result.stdout);
}

// fn getRepoStashCounts(dir: Str): Table[Str, int] =
//     var (output, exitcode) = gitCmd(@["stash", "list"], dir)
//     if exitcode != 0:
//         stderr.writeLine &"Couldn't get stash list ({exitcode})"

//     // stash output looks like:
//     // stash@{0}: On (no branch): push file to stash
//     // stash@{1}: WIP on master: 8dbbdc4 commit one
//     // https://www.git-scm.com/docs/git-stash//Documentation/git-stash.txt-listltoptionsgt
//     for line in output.splitLines[0..^2]:
//         if line =~ re"^[^:]+:[^:]+?(\S+):":
//             result.mgetOrPut(matches[0], 0) += 1
//         elif line.split(':')[1].Strip == "autostash":
//             result.mgetOrPut("-autostash", 0) += 1
//         else:
//             stderr.writeLine &"Stash line didn't match: {line}"


fn parseCode(statusCode: Str) Status {
    // see https://git-scm.com/docs/git-status//_short_format for meaning of codes
    if (eql(u8, statusCode, "??"))
        return Status.untracked;

    var index = statusCode[0];
    var worktree = statusCode[1];

    if (index == 'R') {
        return Status.renamed;
    } else if (index != ' ') {
        if(worktree != ' '){
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
        if (std.mem.eql(u8, rstrip(line), ""))
            continue;

        var code = line[0..2];
        var c = parseCode(code);
        if(c == Status.renamed){
            // renamed files have two lines of status, skip the next line
            codes[@enumToInt(Status.staged)] += 1;
            skip = true;
        } else {
            codes[@enumToInt(c)] += 1;
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
    var i = @enumToInt(Status.modified);
    assert(codes[i] == 2);
    assert(2 == 2);
}

fn parseAheadBehind(source: Str) AheadBehind {
    var result = AheadBehind{};

    var bracketPos = std.mem.indexOf(u8, source, "[") orelse return result;
    if (std.mem.indexOfPos(u8, source, bracketPos+1, "ahead ")) |aheadPos|
        result.ahead = parseDigit(source[aheadPos+6..]);
    if (std.mem.indexOfPos(u8, source, bracketPos+1, "behind ")) |behindPos|
        result.behind = parseDigit(source[behindPos+7..]);

    return result;
}

test "parse ahead/behind" {
    var source = "## master...origin/master [ahead 3, behind 2]";
    var result = parseAheadBehind(source);
    expect(result.ahead == 3);
    expect(result.behind == 2);

    var source2 = "## master...origin/master";
    result = parseAheadBehind(source2);
    expect(result.ahead == 0);
    expect(result.behind == 0);

    var source3 = "## master...origin/master [ahead 3]";
    result = parseAheadBehind(source3);
    expect(result.ahead == 3);
    expect(result.behind == 0);
}

fn parseDigit(source: Str) u32 {
    // source should be a slice pointing to the right position in the string
    // find the integer at the start of 'source', return 0 if no digits found
    var it = std.mem.tokenize(source, ", ]");
    var val = it.next() orelse return 0;
    return std.fmt.parseInt(u32, val, 10) catch return 0;
}

test "parse digits from string" {
    var str = "123]";
    var digit = parseDigit(str);
    expect(digit == 123);
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
    var status: [STATUS_LEN]u32 = [_]u32{0} ** STATUS_LEN;
    var lines = std.mem.split(status_txt.*, "\x00");
    var finalLines = std.ArrayList(Str).init(A);
    defer finalLines.deinit();
    while (lines.next()) |line| {
        // std.debug.print("Line: '{}', type: '{}'\n", .{line, @typeName(@TypeOf(line))});
        var stripped_line = rstrip(line);
        finalLines.append(stripped_line) catch |err| {
            dp("Error when appending: {}", .{err});
            return status;
        };
    }

    var x = finalLines.toOwnedSlice();

    // set ahead, behind
    var ahead_behind = parseAheadBehind(x[0]);
    status[@enumToInt(Status.ahead)] = ahead_behind.ahead;
    status[@enumToInt(Status.behind)] = ahead_behind.behind;

    var statusCodes = parseStatusLines(x[1..]);
    return statusCodes;
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
    expect(status[@enumToInt(Status.untracked)] == 5);
}

fn getStatus(dir: Str) ![STATUS_LEN]u32 {
    // get and parse status codes
    var cmd = [_]Str{"status", "-zb"};
    var result = try gitCmd(&cmd, dir);
    if (result.term.Exited != 0)
        return error.GitStatusFailed;

    return parseStatus(&result.stdout);
}

fn isGitRepo(dir: Str) bool {
    var cmd = [_]Str{"rev-parse", "--is-inside-work-tree"};
    var result = gitCmd(&cmd, dir) catch |err| {
        std.log.err("Couldn't read git repo at {}. Err: {}", .{dir, err});
        return false;
    };
    return result.term.Exited == 0;
}

fn writeFormat(shell: Shell, code: Str) !void {
    if (shell == .zsh){
        try print("{}{}{}", .{"%{", code, "%}"});
    } else {
        try print("{}", .{code});
    }
}

fn styleWrite(shell: Shell, color: Str, value: Str) !void {
    try writeFormat(shell, color);
    try print("{}", .{value});
    try writeFormat(shell, C.reset);
}

fn writeStatusStr(shell: Shell, status: GitStatus) !void {
    // o, c = e[shell].o.replace('{', '{{'), e[shell].c.replace('}', '}}')
    const format = .{
        // using arrays over tuples failed
        .{.color = C.green, .token = @as(Str, "↑"), .status = Status.ahead},
        .{.color = C.red, .token = @as(Str, "↓"), .status = Status.behind},
        .{.color = C.green, .token = @as(Str, "●"), .status = Status.staged},
        .{.color = C.yellow, .token = @as(Str, "+"), .status = Status.modified},
        .{.color = C.red, .token = @as(Str, "-"), .status = Status.removed},
        .{.color = C.cyan, .token = @as(Str, "…"), .status = Status.untracked},
        .{.color = C.blue, .token = @as(Str, "⚑"), .status = Status.stashed},
        .{.color = C.red, .token = @as(Str, "✖"), .status = Status.conflicted},
    };

    // print state
    // if (!std.mem.eql(u8, status.state, "")) {
    //     try styleWrite(shell, C.magenta, status.state);
    //     try print(" ", .{});
    // }

    // print branch
    try styleWrite(shell, C.yellow, status.branch);

    // print stats
    var printed_space = false;
    inline for (format) |f| {
        var skip = false;
        var str: Str = undefined;
        if (f.status == Status.stashed) {
            str = ""; // formatStashes(status);
        } else {
            var num = status.status[@enumToInt(f.status)];
            if (num == 0) {
                str = "";
            } else {
                var buffer: [10]u8 = undefined;
                const buf = buffer[0..];
                str = try std.fmt.bufPrint(buf, "{}", .{num});
            }
        }
        if (!std.mem.eql(u8, str, "")) {
            if (!printed_space){
                try print(" ", .{});
                printed_space = true;
            }
            var strings = [_]Str{ f.token, str };
            var temp = try std.mem.concat(A, u8, &strings);
            try styleWrite(shell, f.color, temp);
        }
    }
}

fn getFullRepoStatus(dir: Str) !GitStatus {
    var branch = async getBranch(dir);
    var status = async getStatus(dir);
    return GitStatus{
        // .state = getState(dir),
        .branch = try await branch,
        .status = try await status,
        // .stash = getRepoStashCounts(dir),
    };
}

pub fn main() !u8 {
    // allocator setup
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    A = &arena.allocator;

    var dir: Str = ".";
    if (std.os.argv.len > 1)
        dir = std.mem.spanZ(std.os.argv[1]);

    if (!isGitRepo(dir))
        return 2; // specific error code for 'not a repository'

    // get the specified shell and initialize escape codes
    var shell = Shell.unknown;
    if (std.mem.len(os.argv) > 1) {
        var arg = std.mem.spanZ(os.argv[1]);
        if (std.mem.eql(u8, arg, "zsh")) {
            shell = Shell.zsh;
        } else if((std.mem.eql(u8, arg, "bash"))) {
            shell = Shell.bash;
        }
    }

    switch (shell) {
        .zsh => { E = Escapes.init("%{", "%}"); },
        .bash => { E = Escapes.init("\\[", "\\]"); },
        else => {
            E = Escapes.init("", "");
            const c = @cImport(@cInclude("stdlib.h"));
            _ = c.unsetenv("SHELL"); // force 'interactive' for subprograms
        }
    }

    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

    var status = try getFullRepoStatus(dir);
    try writeStatusStr(shell, status);
    return 0;
}
