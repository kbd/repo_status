import
  algorithm,
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
    stash: string


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


proc myparseint(s: string): int =
  if s == "":
    return 0

  return parseInt s


proc parseAheadBehind(s: string): (int, int) =
  if s =~ re"[^[]+?\[(?:ahead (\d+))?(?:, )?(?:behind (\d+))?\]$":
    let (ahead, behind) = (myparseint matches[0], myparseint matches[1])
    return (ahead, behind)

  return (0, 0)


proc parseStatusCodes(statusLines: seq[string]): seq[StatusCode] =
  # parse the 'git status -z' output and return a sequence of codes
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
  echo &"Executing {cmd}"
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
  stdout.styledWrite fgMagenta, status.state

  # print branch
  stdout.styledWrite fgYellow, status.branch

  # print stats
  for (color, token, code) in format:
    let num = status.status.getOrDefault(code)
    if num != 0:
      stdout.styledWrite color, token, $num


proc getRepoBranch(dir: string): string =
  var cmd = @["rev-parse", "HEAD", "--"]
  var (output, exitcode) = gitCmd(cmd, dir)

  if exitcode == 128: # no HEAD, empty repo
    return "master"

  cmd = @["describe", "--all", "--contains", "--always", "HEAD"]
  (output, exitcode) = gitCmd(cmd, dir)
  return output.strip


proc getStashCounts(dir: string): string =
  return ""
  # def get_stash_counts(repo):
  #   stash_counts = Counter()

  #   if repo.head_is_unborn:
  #       return stash_counts  # can't stash on new repo

  #   stashes = check_output(['git', 'stash', 'list'], cwd=repo.workdir).decode().splitlines()
  #   getbranch = re.compile(r'^[^:]+:[^:]+?(\S+):')
  #   for stash in stashes:
  #       match = getbranch.match(stash)
  #       if match:
  #           # count the branch name
  #           stash_counts.update([match[1]])
  #       elif stash.split(':')[1].strip() == 'autostash':
  #           # count autostash
  #           stash_counts.update(['-autostash'])

  #   return stash_counts


proc getRepoStashes(dir: string): string =
  ## Return a string like 1A for one stash on a branch and one autostash.
  ##
  ##  If a count is zero, indicate by leaving it out.
  # counter = get_stash_counts(repo)
  # if not counter:  # if no stashes, don't get stats
  #     return ''
  # else:
  #     _total, branch_count, autostash = get_stash_stats(repo, counter)
  #     branch_str = str(branch_count or '')
  #     autostash_str = f"A{autostash if autostash > 1 else ''}" if autostash else ''
  #     return f"{branch_str}{autostash_str}"
  return ""


proc getRepoStatus(dir: string): Table[StatusCode, int] =
  # get and parse status codes
  let cmd = @["status", "-zb"]
  var (output, exitcode) = gitCmd(cmd, dir)

  var statusLines = output.split '\0'
  let branchLine = statusLines[0]
  statusLines.delete(0)
  # remove last (empty) element because we split instead of "splitlines"
  statusLines.delete(len(statusLines) - 1)

  let statusCodes = parseStatusCodes(statusLines)
  var status = initTable[StatusCode, int]()

  # set ahead, behind
  let (a, b) = parseAheadBehind(branchLine)
  status[ahead] = a
  status[behind] = b

  # populate the status table
  for s in statusCodes:
    status.mgetOrPut(s, 0) += 1

  # get stashes
  status[stashed] = 1

  return status


proc printRepoStatus(dir: string): int =
  # create the overall GitStatus
  var gitstatus = (
    state: getRepoState(dir),
    branch: getRepoBranch(dir),
    status: getRepoStatus(dir),
    stash: getRepoStashes(dir),
  )

  # format the status codes into a string suitable for printing in the prompt
  writeStatusStr(gitstatus)

  return 0


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
  var maxerr = 0
  for dir in dirs:
    var err = printRepoStatus(dir)
    err = max(err, maxerr)

  return maxerr


if isMainModule:
  quit(main(parseOpts()))
