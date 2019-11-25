# repo_status

Put git repository status in your command prompt

Depends on libgit2, which must be installed. Only Python requirement is pygit2.

Example:

![Example of repo_status](images/example.png)

The `-f` stands for "fake", to show fake data to see what every possibility
looks like. The first 2 is repository status, and can be an 'R' or an 'M' if in
a rebase or merge, for example.

Next, the '`>`' indicates that you're in a sub-repo.

The rest of the codes mean:

- ahead of upstream
- behind upstream
- staged files
- changed files
- deleted files
- stashed files
- untracked files
- conflicted files

The ✖ is a little out of sorts because that character isn't supported in my
font, YMMV.
