import
  algorithm,
  math,
  os,
  osproc,
  parseopt,
  re,
  sequtils,
  strformat,
  strutils,
  tables,
  terminal


type
  StatusCode = enum
    ahead
    behind
    staged
    added
    modified
    removed
    stashed
    untracked
    conflicted
    renamed
    unknown

type
  GitStatus = tuple
    state: string
    branch: string
    status: Table[StatusCode, int]
    stash: Table[string, int]


proc parse(statusCode: string): StatusCode =
  # see https://git-scm.com/docs/git-status#_short_format for meaning of codes
  if statusCode == "??":
    return untracked

  let index = statusCode[0]
  let worktree = statusCode[1]

  if index == 'R':
    return renamed
  elif index != ' ':
    return staged

  case worktree:
    of 'A':
      return added
    of 'M':
      return modified
    of 'D':
      return removed
    else:
      return unknown


func myparseint(s: string): int =
  if s == "": 0 else: parseInt s


proc parseAheadBehind(s: string): (int, int) =
  if s =~ re"[^[]+?\[(?:ahead (\d+))?(?:, )?(?:behind (\d+))?\]$":
    let (ahead, behind) = (myparseint matches[0], myparseint matches[1])
    return (ahead, behind)

  return (0, 0)


proc parseStatusCodes(statusLines: seq[string]): seq[StatusCode] =
  ## parse the 'git status -z' output and return a sequence of codes
  if len(statusLines) == 0:
    return

  var codes: seq[StatusCode]
  var i = 0
  while i < statusLines.len:
    let code = statusLines[i][0..<2]
    let c = code.parse
    if c == renamed:
      codes.add(staged)
      i.inc # skip next line (the renamed file)
    else:
      codes.add(c)

    i.inc

  return codes


proc gitCmd(cmd: seq[string], workingdir: string): tuple[output: string,
    exitcode: int] =
  ## Return the string result of the git command and the exit code
  var gitcmd = @["git", "-C", workingdir]
  let cmd = gitcmd.concat(cmd).join(" ")
  # echo &"Executing {cmd}"
  return execCmdEx cmd


proc getRepoState(git_dir_path: string): string =
  ## Return a code for the current repo state.
  ##
  ## Possible states:
  ##     R - rebase
  ##     M - merge
  ##     C - cherry-pick
  ##     B - bisect
  ##     V - revert
  ##
  ## The code returned will indicate multiple states (if that's possible?)
  ## or the empty string if the repo is in a normal state.

  # Unfortunately there's no porcelain to check for various git states.
  # Determining state is done by checking for the existence of files within
  # the git repository. Reference for possible checks:
  # https://github.com/git/git/blob/master/contrib/completion/git-prompt.sh
  let checks = {
    "rebase-merge": 'R',
    "rebase-apply": 'R',
    "MERGE_HEAD": 'M',
    "CHERRY_PICK_HEAD": 'C',
    "BISECT_LOG": 'B',
    "REVERT_HEAD": 'V',
  }.toTable

  var state_set: set[char]
  for filename, status_code in checks:
    let path = git_dir_path / filename
    if path.fileExists:
      state_set.incl status_code

  return join(state_set.toSeq.sorted, "")


proc formatStashes(status: GitStatus): string =
  ## Return a string like 1A for one stash on current branch and one autostash
  ## todo: also display count of all stashes?
  # let total = sum(toSeq(status.stash.values))
  let branch_count = status.stash.getOrDefault(status.branch)
  let autostash = status.stash.getOrDefault("-autostash")

  if branch_count > 0:
    result &= $branch_count

  if autostash > 0:
    result &= 'A'


proc writeStatusStr(status: GitStatus) =
  # o, c = e[shell].o.replace('{', '{{'), e[shell].c.replace('}', '}}')
  let format = [
    (fgGreen, "↑", ahead),
    (fgRed, "↓", behind),
    (fgGreen, "●", staged),
    (fgYellow, "+", modified),
    (fgRed, "-", removed),
    (fgCyan, "…", untracked),
    (fgBlue, "⚑", stashed),
    (fgRed, "✖", conflicted),
  ]

  # print state
  if status.state != "":
    stdout.styledWrite fgMagenta, status.state
    stdout.write ' '

  # print branch
  stdout.styledWrite fgYellow, status.branch

  # print stats
  var stats: seq[tuple[color: ForegroundColor, token: string, value: string]]
  for (color, token, code) in format:
    if code == stashed:
      let stashstr = formatStashes(status)
      if stashstr == "":
        continue
      stats.add((color, token, stashstr))
    else:
      let num = status.status.getOrDefault(code)
      if num != 0:
        stats.add((color, token, $num))

  if len(stats) > 0:
    stdout.write ' '
    for (color, token, value) in stats:
      stdout.styledWrite color, token, value


proc getRepoBranch(dir: string): string =
  var cmd = @["rev-parse", "HEAD", "--"]
  var (output, exitcode) = gitCmd(cmd, dir)

  if exitcode == 128: # no HEAD, empty repo
    return "master"

  cmd = @["describe", "--all", "--contains", "--always", "HEAD"]
  (output, exitcode) = gitCmd(cmd, dir)
  return output.strip


proc getRepoStashCounts(dir: string): Table[string, int] =
  let (output, exitcode) = gitCmd(@["stash", "list"], dir)
  if exitcode != 0:
    stderr.writeLine &"Couldn't get stash list ({exitcode})"

  # stash output looks like:
  # stash@{0}: On (no branch): push file to stash
  # stash@{1}: WIP on master: 8dbbdc4 commit one
  # https://www.git-scm.com/docs/git-stash#Documentation/git-stash.txt-listltoptionsgt
  for line in output.splitLines[0..^2]:
    if line =~ re"^[^:]+:[^:]+?(\S+):":
      result.mgetOrPut(matches[0], 0) += 1
    elif line.split(':')[1].strip == "autostash":
      result.mgetOrPut("-autostash", 0) += 1
    else:
      stderr.writeLine &"Stash line didn't match: {line}"


proc getRepoStatus(dir: string): Table[StatusCode, int] =
  # get and parse status codes
  let cmd = @["status", "-zb"]
  var (output, exitcode) = gitCmd(cmd, dir)
  var statusLines = output.split '\0'

  # populate the result
  # cut off first branch line and the last line, which is empty because
  # git status -z ends in null
  let statusCodes = parseStatusCodes(statusLines[1..^2])
  for s in statusCodes:
    result.mgetOrPut(s, 0) += 1

  # set ahead, behind
  let (a, b) = parseAheadBehind(statusLines[0])
  result[ahead] = a
  result[behind] = b


proc isGitRepo(dir: string): bool =
  let (_, exitcode) = gitCmd(@["rev-parse", "--is-inside-work-tree"], dir)
  return exitcode == 0


proc printRepoStatus(dir: string): int =
  # check if in git repo
  if not isGitRepo(dir):
    return 2 # specific error code for 'not in a repository'

  # get repo info
  var gitstatus = (
    state: getRepoState(dir),
    branch: getRepoBranch(dir),
    status: getRepoStatus(dir),
    stash: getRepoStashCounts(dir),
  )

  # format the status codes into a string suitable for printing in the prompt
  writeStatusStr(gitstatus)


proc parseOpts(): seq[string] =
  # parse args
  # git -C <path> rev-parse
  var p = initOptParser()

  # give a list of directories to get the status for
  # if no directory provided, use .
  var dirs: seq[string]
  for kind, key, val in p.getopt():
    let foo = &"{kind}, {key}, {val}"
    case kind
    of cmdArgument:
      dirs.add(key)
    else:
      echo &"invalid command line argument: {foo}"

  if len(dirs) == 0:
    dirs.add(".")

  return dirs


proc main(dirs: seq[string]): int =
  for dir in dirs:
    var err = printRepoStatus(dir)
    result = max(err, result)


if isMainModule:
  quit(main(parseOpts()))
