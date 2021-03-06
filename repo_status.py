#!/usr/bin/env python3
"""Print repo status.

Currently only supports git.

Inspiration taken from:
https://github.com/olivierverdier/zsh-git-prompt
https://github.com/yonchu/zsh-vcs-prompt
zsh's vcs_info

todo:
* support other vcs?
* rewrite in C using libgit2 directly?
"""
import argparse
import os
import re
import sys
from collections import Counter
from pathlib import Path
from subprocess import DEVNULL, check_output

import pygit2 as git


# colors
# https://en.wikipedia.org/wiki/ANSI_escape_code
class D(dict):
  __getattr__ = dict.__getitem__

colors = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white']
style_codes = dict(reset=0, bold=1, it=3, ul=4, rev=7, it_off=23, ul_off=24, rev_off=27)
esc = lambda i: f'\x1b[{i}m'

# s = style, fg = foreground, bg = background
s = D({name: esc(i) for name, i in style_codes.items()})
fg = D({colors[i]: esc(30+i) for i in range(8)})
bg = D({colors[i]: esc(40+i) for i in range(8)})

e = D(  # e = escapes for use within prompt, o=open, c=close
    zsh=D(o='%{', c='%}'),
    bash=D(o='\\[\x1b[', c='\\]'),
    interactive=D(o='', c=''),
)


def get_git_statuses():
    # {
    #     0: 'GIT_STATUS_CURRENT',
    #     1: 'GIT_STATUS_INDEX_NEW',
    #     2: 'GIT_STATUS_INDEX_MODIFIED',
    #     4: 'GIT_STATUS_INDEX_DELETED',
    #     8: 'GIT_STATUS_INDEX_RENAMED',
    #     16: 'GIT_STATUS_INDEX_TYPECHANGE',
    #     128: 'GIT_STATUS_WT_NEW',
    #     256: 'GIT_STATUS_WT_MODIFIED',
    #     512: 'GIT_STATUS_WT_DELETED',
    #     1024: 'GIT_STATUS_WT_TYPECHANGE',
    #     2048: 'GIT_STATUS_WT_RENAMED',
    #     4096: 'GIT_STATUS_WT_UNREADABLE'
    #     16384: 'GIT_STATUS_IGNORED',
    #     32768: 'GIT_STATUS_CONFLICTED',
    # }
    statuses = {
        getattr(git, s): s
        for s in (attr for attr in vars(git)
        if attr.startswith('GIT_STATUS_'))
    }
    del statuses[0]  # unnecessary
    return statuses


def get_shell():
    # assume this program's parent is the shell. Not ideal, but no reliable way.
    # TODO: allow to specify the shell as command line argument
    cmd = f'ps -p {os.getppid()} -ocomm='
    shell = check_output(cmd, shell=True).decode().strip()
    # can be things like '-zsh', 'zsh', or '/usr/local/bin/zsh'
    return re.sub(r'[^A-Za-z0-9._]+', '', os.path.basename(shell))


def get_templates(shell):
    o, c = e[shell].o.replace('{', '{{'), e[shell].c.replace('}', '}}')
    return {
        'state': f'{o}{fg.magenta}{c}{{}}{o}{s.reset}{c}',
        'parent': f'{o}{fg.yellow}{s.bold}{c}>{o}{s.reset}{c}',
        'branch': f'{o}{fg.yellow}{c}{{}}{o}{s.reset}{c}',
        'space': ' ',
        'ahead': f'{o}{fg.green}{c}↑{{}}{o}{s.reset}{c}',
        'behind': f'{o}{fg.red}{c}↓{{}}{o}{s.reset}{c}',
        'conflicted': f'{o}{fg.red}{c}✖{{}}{o}{s.reset}{c}',
        'modified': f'{o}{fg.yellow}{c}+{{}}{o}{s.reset}{c}',
        'deleted': f'{o}{fg.red}{c}-{{}}{o}{s.reset}{c}',
        'staged': f'{o}{fg.green}{c}●{{}}{o}{s.reset}{c}',
        'stashed': f'{o}{fg.blue}{c}⚑{{}}{o}{s.reset}{c}',
        'untracked': f'{o}{fg.cyan}{c}…{{}}{o}{s.reset}{c}',
    }


def repo_state(repo):
    """Return a code for the current repo state.

    Possible states:
        R - rebase
        M - merge
        C - cherry-pick
        B - bisect
        V - revert

    The code returned will indicate multiple states (if that's possible?)
    or the empty string if the repo is in a normal state.
    """
    # Unfortunately there's no porcelain to check for various git states.
    # Determining state is done by checking for the existence of files within
    # the git repository. Reference for possible checks:
    # https://github.com/git/git/blob/master/contrib/completion/git-prompt.sh#L397
    checks = {
        'rebase-merge': 'R',
        'rebase-apply': 'R',
        'MERGE_HEAD': 'M',
        'CHERRY_PICK_HEAD': 'C',
        'BISECT_LOG': 'B',
        'REVERT_HEAD': 'V',
    }
    git_files = {p.name for p in Path(repo.path).iterdir()}
    present_files = checks.keys() & git_files
    statuses = {checks[p] for p in present_files}
    return ''.join(sorted(statuses))


def get_repo(dir):
    path = git.discover_repository(dir)
    if not path:
        return None

    return git.Repository(path)


def get_repo_branch(repo):
    if repo.head_is_detached:
        # gives things like 'tags/tag_name' or 'heads/branch_name' if
        # there's a tag or branch pointing to the current commit.
        # Otherwise, gives 'master~2' if detached two commits behind master.
        # Finally, fall back to short commit id as fallback
        # Evidently there's no equivalent call in libgit2
        cmd = ['git', 'describe', '--all', '--contains', '--always', 'HEAD']
        out = check_output(cmd, cwd=repo.workdir, stderr=DEVNULL)
        return out.decode().strip()
    elif repo.head_is_unborn:  # brand new empty repo
        return 'master'

    return repo.head.shorthand


def get_stash_counts(repo):
    stash_counts = Counter()

    if repo.head_is_unborn:
        return stash_counts  # can't stash on new repo

    stashes = check_output(['git', 'stash', 'list'], cwd=repo.workdir).decode().splitlines()
    getbranch = re.compile(r'^[^:]+:[^:]+?(\S+):')
    for stash in stashes:
        match = getbranch.match(stash)
        if match:
            # count the branch name
            stash_counts.update([match[1]])
        elif stash.split(':')[1].strip() == 'autostash':
            # count autostash
            stash_counts.update(['-autostash'])

    return stash_counts


def get_stash_stats(repo, counter):
    """Return a tuple of counts, (total, branch, autostash)"""
    return len(counter), counter[repo.head.shorthand], counter['-autostash']


def get_stash_string(repo):
    """Return a string like 1A for one stash on a branch and one autostash.

    If a count is zero, indicate by leaving it out.
    """
    counter = get_stash_counts(repo)
    if not counter:  # if no stashes, don't get stats
        return ''
    else:
        _total, branch_count, autostash = get_stash_stats(repo, counter)
        branch_str = str(branch_count or '')
        autostash_str = f"A{autostash if autostash > 1 else ''}" if autostash else ''
        return f"{branch_str}{autostash_str}"


def get_repo_status(repo):
    status = {} if repo.is_bare else repo.status()
    counts = Counter(status.values())
    final_counts = Counter()
    statuses = get_git_statuses()
    status_codes = sorted(statuses, reverse=True)
    # go over the counts and split up the flags
    for code, count in counts.items():
        for status_code in status_codes:
            if status_code & code:
                final_counts[status_code] += count

    return {
        status_name: final_counts[code]
        for code, status_name in statuses.items()
    }


def get_ahead_behind(repo):
    if repo.head_is_unborn or repo.head_is_detached:
        return 0, 0

    local = repo.head
    upstream = repo.branches[repo.head.shorthand].upstream
    if not upstream:
        return 0, 0

    return repo.ahead_behind(local.target, upstream.target)


def get_repo_info(repo):
    """Return a dictionary of repository info"""
    ahead, behind = get_ahead_behind(repo)
    status = get_repo_status(repo)
    # count anything in the index as staged
    staged = sum(v for k, v in status.items() if k.startswith('GIT_STATUS_INDEX'))
    parent_repo = check_output(['git', 'rev-parse', '--show-superproject-working-tree'],
        cwd=repo.workdir)
    result = {  # this order is how we want things displayed (req. 3.6 dict ordering)
        'state': repo_state(repo),
        'parent': parent_repo,
        'branch': get_repo_branch(repo),
        'ahead': ahead,
        'behind': behind,
        'staged': staged,
        'modified': status['GIT_STATUS_WT_MODIFIED'] + status['GIT_STATUS_WT_TYPECHANGE'],
        'deleted': status['GIT_STATUS_WT_DELETED'],
        'stashed': get_stash_string(repo),
        'untracked': status['GIT_STATUS_WT_NEW'],
        'conflicted': status['GIT_STATUS_CONFLICTED'],
    }
    return result


def print_repo_info(repo_info, templates):
    results = []
    for k, v in repo_info.items():
        if v:
            results.append(templates[k].format(v))
        if k == 'branch' or (k == 'state' and v):
            # insert a space after branch or state
            results.append(templates['space'])

    print(''.join(results).strip(), end='')


def main(args):
    repo = get_repo(args.path)
    if not repo:
        return 2  # 2 is specific error for 'not a repository'

    info = get_repo_info(repo)
    if args.fake:
        info.update({k: 2 for k in info if k != 'branch'})

    shell = get_shell()
    if os.isatty(1) or args.interactive or shell not in ('bash', 'zsh'):
        shell = 'interactive'

    templates = get_templates(shell)
    print_repo_info(info, templates)
    return 0


def parse_args():
    parser = argparse.ArgumentParser(description='Print repo status')
    parser.add_argument('path', nargs='?', default='.', help='Path to repository')
    parser.add_argument('-f', '--fake', action='store_true', help='Show fake status')
    parser.add_argument('-i', '--interactive', action='store_true', help="'Interactive' mode (don't print shell escapes)")
    return parser.parse_args()


if __name__ == '__main__':
    args = parse_args()
    sys.exit(main(args))
