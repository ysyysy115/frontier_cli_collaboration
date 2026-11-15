"""agy PreToolUse hook (run_command): block high-risk commands.

A backstop, not the main control: the preamble tells the advisor not to change the repository. This guard
hard-blocks only what is hard to undo: deleting files, state-changing git, and package installs. Other writes
are caught by the git snapshot that advise.ps1 compares before and after every call. Fails closed.
"""
import json
import os
import re
import sys

# git <global options> <subcommand> <rest of the segment>
GIT_CALL = re.compile(r'''\bgit(?:\.exe)?["']?((?:\s+(?:-C\s+(?:"[^"]*"|'[^']*'|\S+)|-c\s+(?:"[^"]*"|\S+)|'''
                      r'''--[\w-]+(?:=(?:"[^"]*"|\S+))?|-[A-Za-z]))*)\s+([\w-]+)([^|;&\n]*)''', re.I)
GIT_WRITE_SUBS = {'commit', 'checkout', 'reset', 'push', 'pull', 'add', 'rm', 'mv', 'merge', 'rebase', 'cherry-pick',
                  'revert', 'clean', 'apply', 'am', 'restore', 'switch', 'init', 'clone', 'fetch', 'gc', 'prune',
                  'update-ref', 'update-index', 'filter-branch', 'filter-repo', 'replace', 'submodule', 'lfs'}
GIT_READ_FORMS = {  # subcommands that are read-only only with these arguments
    'stash': re.compile(r'^\s*(list|show)\b'),
    'tag': re.compile(r'^\s*($|-l\b|--list\b|-n\b|--contains\b|--points-at\b)'),
    'branch': re.compile(r'^(?!.*\s-[dDmMcCfu]\b)(?!.*--(delete|move|copy|force|set-upstream|unset-upstream|edit-description)\b)'),
    'config': re.compile(r'^\s*(--get\b|--get-all\b|--get-regexp\b|--list\b|-l\b)'),
    'worktree': re.compile(r'^\s*list\b'),
    'notes': re.compile(r'^\s*(list|show)\b'),
    'remote': re.compile(r'^(?!.*\b(add|remove|rm|rename|set-url|set-head|prune|update)\b)'),
}


def git_write(cmd):
    for m in GIT_CALL.finditer(cmd):
        sub, rest = m.group(2).lower(), m.group(3)
        if sub in GIT_WRITE_SUBS:
            return True
        if sub in GIT_READ_FORMS and not GIT_READ_FORMS[sub].search(rest):
            return True
    return False
INSTALL = re.compile(r'\b(pip|pip3|uv|conda|mamba|micromamba|npm|pnpm|yarn|winget|choco|scoop)\b[^|;&\n]*\b'
                     r'(install|uninstall|remove|update|upgrade|add|create|env\s+remove)\b', re.I)
DELETE = re.compile(r'(\bRemove-Item\b|\bri\s|\bdel\b|\berase\b|\brmdir\b|\brd\s|\brm\s|\bunlink\b|'
                    r'shutil\.rmtree|os\.remove|os\.unlink|os\.rmdir|\.unlink\(|\.rmdir\(|'
                    r'\bClear-Content\b|\bClear-RecycleBin\b|\bFormat-Volume\b|\bdiskpart\b|\btruncate\b)', re.I)


def decide(payload):
    call = payload.get('toolCall') or {}
    args = call.get('args') or {}
    cmd = str(args.get('CommandLine') or args.get('command') or '')
    reason = None
    if git_write(cmd):
        reason = 'state-changing git commands'
    elif INSTALL.search(cmd):
        reason = 'installing or removing packages and environments'
    elif DELETE.search(cmd):
        reason = 'deleting files'
    if reason:
        return call, cmd, {'decision': 'deny',
                           'reason': f'Advisor guard: {reason} is not allowed for advisors. Read-only git '
                                     f'(log, show, diff, status, blame, grep) is fine. If you need this, say so in '
                                     f'your answer and the main agent will do it.'}
    return call, cmd, {'decision': 'allow'}


def main():
    call, cmd, out = {}, '', None
    try:
        call, cmd, out = decide(json.loads(sys.stdin.read()))
    except Exception as e:  # fail closed
        out = {'decision': 'deny', 'reason': f'Advisor command guard error: {e!r}'}
    log = os.environ.get('GUARD_LOG')
    if log:
        try:
            with open(log, 'a', encoding='utf-8') as f:
                f.write(json.dumps({'tool': call.get('name'), 'cmd': cmd[:400], 'decision': out['decision'],
                                    'reason': out.get('reason')}) + '\n')
        except Exception:
            pass
    print(json.dumps(out))


main()
