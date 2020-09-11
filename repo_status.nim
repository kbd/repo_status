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

type
  Shell = enum
    zsh, interactive


proc parse(statusCode: string): StatusCode =
  # see https://git-scm.com/docs/git-status#_short_format for meaning of codes
  if statusCode == "??":
    return untracked

  let index = statusCode[0]
  let worktree = statusCode[1]

  if index == 'R':
    return renamed
  elif index != ' ':
    if worktree != ' ':
      return conflicted
    else:
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
    result = (myparseint matches[0], myparseint matches[1])


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
  return execCmdEx cmd


proc getGitDir(dir: string): string =
  let (gitdir, exitcode) = gitCmd(@["rev-parse", "--git-dir"], dir)
  if exitcode != 0:
    stderr.writeLine &"Couldn't get git dir for {dir}"
  return gitdir.strip


proc getRepoState(dir: string): string =
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

  let git_dir = getGitDir(dir)

  var state_set: set[char]
  for filename, status_code in checks:
    let path = git_dir / filename
    if path.fileExists or path.dirExists:
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


proc writeFormat(shell: Shell, code: string) =
  if shell == zsh:
    stdout.write "%{", code, "%}"
  else:
    stdout.write code


proc styleWrite(shell: Shell, color: ForegroundColor, value: string) =
  writeFormat shell, ansiForegroundColorCode(color)
  stdout.write value
  writeFormat shell, ansiForegroundColorCode(fgDefault)


proc writeStatusStr(shell: Shell, status: GitStatus) =
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
    styleWrite shell, fgMagenta, status.state
    stdout.write ' '

  # print branch
  styleWrite shell, fgYellow, status.branch

  # print stats
  var stats: seq[tuple[color: ForegroundColor, value: string]]
  for (color, token, code) in format:
    if code == stashed:
      let stashstr = formatStashes(status)
      if stashstr == "":
        continue
      stats.add((color, token & stashstr))
    else:
      let num = status.status.getOrDefault(code)
      if num != 0:
        stats.add((color, token & $num))

  if len(stats) > 0:
    stdout.write ' '
    for (color, value) in stats:
      styleWrite shell, color, value


proc getRepoBranch(dir: string): string =
  var cmd = @["symbolic-ref", "HEAD", "--short"]
  var (output, exitcode) = gitCmd(cmd, dir)
  if exitcode == 0:
    return output.strip

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
  if exitcode != 0:
    stderr.writeLine &"Couldn't get status from repository. Output: {output}"
    quit(1)

  var statusLines = output.split('\0').filterIt(it.strip != "")

  # set ahead, behind
  (result[ahead], result[behind]) = parseAheadBehind(statusLines[0])

  # cut off first line containing the branch
  let statusCodes = parseStatusCodes(statusLines[1..^1])
  for s in statusCodes:
    result.mgetOrPut(s, 0) += 1


proc isGitRepo(dir: string): bool =
  let (_, exitcode) = gitCmd(@["rev-parse", "--is-inside-work-tree"], dir)
  return exitcode == 0


proc getFullRepoStatus(dir: string): GitStatus =
  (
    state: getRepoState(dir),
    branch: getRepoBranch(dir),
    status: getRepoStatus(dir),
    stash: getRepoStashCounts(dir),
  )


proc parseOpts(): string =
  result = "."

  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      result = key
    else:
      echo &"invalid command line argument: {kind}, {key}, {val}"


proc main(dir: string): int =
  if not isGitRepo(dir):
    return 2 # specific error code for 'not a repository'

  let is_zsh = os.getEnv("SHELL").contains("zsh")
  let shell = if terminal.isatty(stdout) or not is_zsh:
      interactive
    else:
      zsh

  let gitstatus = getFullRepoStatus(dir)
  writeStatusStr(shell, gitstatus)


if isMainModule:
  quit(main(parseOpts()))
