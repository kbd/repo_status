import
  osproc,
  parseopt,
  sequtils,
  strformat,
  strutils,
  tables


type
  StatusCode = enum
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
    unknown


proc parse(statusCode: string): StatusCode =
  # from https://git-scm.com/docs/git-status
  #
  # For paths with merge conflicts, X and Y show the modification states of each
  # side of the merge. For paths that do not have merge conflicts, X shows the
  # status of the index, and Y shows the status of the work tree. For untracked
  # paths, XY are ??. Other status codes can be interpreted as follows:
  #
  #   ' ' = unmodified
  #   M = modified
  #   A = added
  #   D = deleted
  #   R = renamed
  #   C = copied
  #   U = updated but unmerged
  #
  # X          Y     Meaning
  # -------------------------------------------------
  #          [AMD]   not updated
  # M        [ MD]   updated in index
  # A        [ MD]   added to index
  # D                deleted from index
  # R        [ MD]   renamed in index
  # C        [ MD]   copied in index
  # [MARC]           index and work tree matches
  # [ MARC]     M    work tree changed since index
  # [ MARC]     D    deleted in work tree
  # [ D]        R    renamed in work tree
  # [ D]        C    copied in work tree
  # -------------------------------------------------
  # D           D    unmerged, both deleted
  # A           U    unmerged, added by us
  # U           D    unmerged, deleted by them
  # U           A    unmerged, added by them
  # D           U    unmerged, deleted by us
  # A           A    unmerged, both added
  # U           U    unmerged, both modified
  # -------------------------------------------------
  # ?           ?    untracked
  # !           !    ignored
  # -------------------------------------------------
  if statusCode == "??":
    return untracked

  let index = statusCode[0]
  let worktree = statusCode[1]
  echo &"index: {index}, worktree: {worktree}"

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


proc parseStatusCodes(status: string): seq[StatusCode] =
  ## parse the 'git status -z' output and return a sequence of codes
  if len(status) == 0:
    return

  var parts = status.split '\0'
  # remove last (empty) element because we split instead of "splitlines"
  parts.delete(len(parts) - 1)
  var codes: seq[StatusCode]
  var i = 0
  while i < parts.len:
    let code = parts[i][0..<2]
    # echo &"code is {repr(code)}"
    let c = code.parse
    if c == renamed:
      codes.add(staged)
      i.inc # skip next line (the renamed file)
    else:
      codes.add(c)

    i.inc

  echo &"Repo status: {parts}, {codes}"
  return codes


proc gitCmd(cmd: seq[string], workingdir: string): tuple[output: string,
    exitcode: int] =
  ## Return the string result of the git command and the exit code
  var gitcmd = @["git", "-C", workingdir]
  let cmd = gitcmd.concat(cmd).join(" ")
  echo &"Executing {cmd}"
  return execCmdEx cmd


proc printRepoStatus(dir: string): int =
  echo &"{dir} master"

  # get and parse status codes
  let cmd = @["status", "-z"]
  var (output, exitcode) = gitCmd(cmd, dir)
  echo &"Exit code was {exitcode}"

  let statusCodes = parseStatusCodes(output)
  echo &"Status was: {statusCodes}"

  var status = initTable[StatusCode, int]()
  # ↑2 ↓2 ●2 +2 -2 ⚑2 …2 ✖2

  for s in statusCodes:
    status.mgetOrPut(s, 0) += 1

  echo status
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

    # echo foo
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
