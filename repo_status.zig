const std = @import("std");
const stdout = std.io.getStdOut().writer();
const print = stdout.print;
const os = std.os;
const Allocator = std.mem.Allocator;
const funcs = @import("funcs.zig");
const proc = std.ChildProcess;
const eql = std.mem.eql;

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

const GitStatus = struct {
    state: Str,
    branch: Str,
    status: std.AutoHashMap(Status, u32),
    // stash: Table[Str, int]
};

fn parse(Status: Str) Status {
    // see https://git-scm.com/docs/git-status//_short_format for meaning of codes
    if(eql(Str, statusCode, "??"))
        return Status.untracked;

    var index = statusCode[0];
    var worktree = statusCode[1];

    if(eql(Str, index, 'R')) {
        return renamed;
     } else if(!eql(Str, index, " ")) {
        if(!eql(Str, worktree, " ")){
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

// func myparseint(s: Str): int =
//     if s == "": 0 else: parseInt s


// fn parseAheadBehind(s: Str): (int, int) =
//     if s =~ re"[^[]+?\[(?:ahead (\d+))?(?:, )?(?:behind (\d+))?\]$":
//         result = (myparseint matches[0], myparseint matches[1])


// fn parseStatusCodes(statusLines: seq[Str]): seq[StatusCode] =
//     //// parse the 'git status -z' output and return a sequence of codes
//     if len(statusLines) == 0:
//         return

//     var codes: seq[StatusCode]
//     var i = 0
//     while i < statusLines.len:
//         var code = statusLines[i][0..<2]
//         var c = code.parse
//         if c == renamed:
//             codes.add(staged)
//             i.inc // skip next line (the renamed file)
//         else:
//             codes.add(c)

//         i.inc

//     return codes

const Str = []const u8;

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


// fn getGitDir(dir: Str): Str =
//     var (gitdir, exitcode) = gitCmd(@["rev-parse", "--git-dir"], dir)
//     if exitcode != 0:
//         stderr.writeLine &"Couldn't get git dir for {dir}"
//     return gitdir.strip


fn getRepoState(dir: Str) !Str {
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
    return "";
}

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


// fn writeFormat(shell: Shell, code: Str) =
//     if shell == zsh:
//         stdout.write "%{", code, "%}"
//     else:
//         stdout.write code


// fn styleWrite(shell: Shell, color: ForegroundColor, value: Str) =
//     writeFormat shell, ansiForegroundColorCode(color)
//     stdout.write value
//     writeFormat shell, ansiForegroundColorCode(fgDefault)


// fn writeStatusStr(shell: Shell, status: GitStatus) =
//     // o, c = e[shell].o.replace('{', '{{'), e[shell].c.replace('}', '}}')
//     var format = [
//         (fgGreen, "↑", ahead),
//         (fgRed, "↓", behind),
//         (fgGreen, "●", staged),
//         (fgYellow, "+", modified),
//         (fgRed, "-", removed),
//         (fgCyan, "…", untracked),
//         (fgBlue, "⚑", stashed),
//         (fgRed, "✖", conflicted),
//     ]

//     // print state
//     if status.state != "":
//         styleWrite shell, fgMagenta, status.state
//         stdout.write ' '

//     // print branch
//     styleWrite shell, fgYellow, status.branch

//     // print stats
//     var stats: seq[tuple[color: ForegroundColor, value: Str]]
//     for (color, token, code) in format:
//         if code == stashed:
//             var stashstr = formatStashes(status)
//             if stashstr == "":
//                 continue
//             stats.add((color, token & stashstr))
//         else:
//             var num = status.status.getOrDefault(code)
//             if num != 0:
//                 stats.add((color, token & $num))

//     if len(stats) > 0:
//         stdout.write ' '
//         for (color, value) in stats:
//             styleWrite shell, color, value

fn rstrip(s: Str) Str {
    return std.mem.trim(u8, s, " \n");
}

fn getRepoBranch(dir: Str) !Str {
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


fn getRepoStatus(dir: Str) std.AutoHashMap(Status, u32) {
    // get and parse status codes
    var cmd = [_]Str{"status", "-z"};
    var result = try gitCmd(&cmd, dir);
    if (result.term.Exited != 0)
        return error.GitStatusFailed;

    var map = std.AutoHashMap(Status, u32);

    var lines = std.mem.split(output, "\0");
    while (lines.next()) |line| {
        if (eql(Str, rstrip(line), ""))
            continue;

    // cut off first line containing the branch
    // var statusCodes = parseStatusCodes(statusLines[1..^1])
    // for s in statusCodes:
    //     result.mgetOrPut(s, 0) += 1



    }
    // // set ahead, behind
    // (result[ahead], result[behind]) = parseAheadBehind(statusLines[0])

}


fn isGitRepo(dir: Str) bool {
    cmd = [_]Str{"rev-parse", "--is-inside-work-tree"};
    var result = try gitCmd(&cmd, dir);
    return result.term.Exited == 0;
}

// fn getFullRepoStatus(dir: Str) !GitStatus {
//     return GitStatus{
//         .state = try getRepoState(dir),
//         .branch = try getRepoBranch(dir),
//         .status = try getRepoStatus(dir),
//         // .stash = getRepoStashCounts(dir),
//     };
// }

// fn parseOpts(): Str =
//     result = "."

//     var p = initOptParser()
//     for kind, key, val in p.getopt():
//         case kind
//         of cmdArgument:
//             result = key
//         else:
//             echo &"invalid command line argument: {kind}, {key}, {val}"


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

pub fn main() !int {
    // allocator setup
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    A = &arena.allocator;

    if (!isGitRepo(dir)){
        return 2; // specific error code for 'not a repository'
    }

    // escapes
    const shell = os.getenv("SHELL") orelse "";
    const is_zsh = std.mem.indexOf(u8, shell, "zsh") != null;
    const called_directly = std.os.isatty(1);
    if (called_directly or !is_zsh) {
        E = Escapes.init("", ""); // interactive
    } else {
        E = Escapes.init("%{", "%}"); // zsh
    }

    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    CWD = try std.os.getcwd(&buf);

    var state = getRepoState(".");
    try print("{}\n", .{state});

    var branch = try getRepoBranch(CWD);
    try print("{}\n", .{branch});

    var status = getRepoStatus(".");
    try print("{}\n", .{status});

    // var gitstatus = getFullRepoStatus(dir)
    // writeStatusStr(shell, gitstatus)
}
