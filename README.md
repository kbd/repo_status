# repo_status

*Put git repository status in your command prompt*

## Disclaimer

Written in [Zig](https://ziglang.org/).

## Introduction

For this repo at time of writing, I have one changed file (this readme) and one
untracked file, so my prompt looks like:

![Example of repo_status](images/prompt.png)

## Details
Here's an example using fake data (all 2s) for every possible field:

![Example of repo_status](images/example.png)

The first '2' is repository status, and can be an 'R' or an 'M' if in
a rebase or merge, for example.

Next, the '`>`' indicates that you're in a sub-repo. After that is the name of
the current branch.

The rest of the codes mean:

- ahead of upstream
- behind upstream
- staged files
- changed files
- deleted files
- stashes on current branch
- untracked files
- conflicted files

The ✖ is a little out of sorts because that character isn't supported in [my
font](https://github.com/belluzj/fantasque-sans), YMMV.

## Interactive use

Primary usage is to put it in your shell prompt, but `repo_status` can also be
used interactively. You can pass `repo_status` a path for it to give the status
of a repository outside of your current directory.

Here's a scenario: you have a "projects" directory (my `~P` in my
screenshot above is a Zsh hashed directory pointing to my projects directory)
and want to look through all your projects and make sure you didn't forget to
push any commits, or see if you have any staged files you forgot to commit, etc.

Run this (this uses the excellent [fd](https://github.com/sharkdp/fd)) to easily
see the status of every repo under the current directory:

```bash
fd -td -d1 | while read -r dir; do
  echo -n "$dir: "
  repo_status "$dir"
  echo ''
done
```

`repo_status` prints nothing if called on a directory that isn't a git repo (and
returns error code `2`).

## Build instructions

```shell
zig build-exe -OReleaseFast repo_status.zig
```
