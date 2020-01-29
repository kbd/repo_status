import
  osproc,
  parseopt,
  sequtils,
  strformat,
  strutils


type
  Status = tuple[
    # ↑2 ↓2 ●2 +2 -2 ⚑2 …2 ✖2
    ahead: int,
    behind: int,
    staged: int,
    added: int,
    removed: int,
    stashed: int,
    untracked: int,
    conflicted: int,
  ]


proc parseStatusCodes(status: string): seq[string] =
  ## parse the 'git status -z' output and return a sequence of codes
  if len(status) == 0:
    return

  var parts = status.split '\0'
  # remove last (empty) element because we split instead of "splitlines"
  parts.delete(len(parts) - 1)
  var codes: seq[string]
  for part in parts:
    let code = part.split(" ", maxsplit = 1)[0]
    codes.add(code)

  echo &"Repo status: {parts}, {codes}"


proc parseStatusCode(statusCode: string): Status =
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
  var status: Status
  status.ahead = 2
  return status


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

  let status = parseStatusCodes(output)
  echo &"Status was: {status}"

  return 0
  # case exitcode:
  #   of 0:
  #     let codes = parseStatusCodes output
  #     for code in codes:
  #       echo parseStatusCode(code)
  #   of 128:
  #     return # not a repo
  #   else:
  #     echo "Unknown error"


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
