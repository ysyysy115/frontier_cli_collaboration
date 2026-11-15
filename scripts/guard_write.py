"""agy PreToolUse hook (write_file, edit_file): allow writes only under GUARD_WORK.

A backstop, not the main control: the preamble tells the advisor where it may write. Fails closed:
any error, or a call with no absolute path, is denied. Each decision is appended to GUARD_LOG.
"""
import json
import os
import sys


def norm(p):
    return os.path.normcase(os.path.realpath(p))


def decide(payload):
    work = norm(os.environ['GUARD_WORK'])
    call = payload.get('toolCall') or {}
    args = call.get('args') or {}
    paths = [v for v in args.values()
             if isinstance(v, str) and (v[1:3] in (':\\', ':/') or v.startswith(('/', '\\')))]
    bad = [p for p in paths if not (norm(p) + os.sep).startswith(work + os.sep)]
    if bad or not paths:
        return call, {'decision': 'deny',
                      'reason': f'Advisor guard: you may create or edit files only under {work} '
                                f'(use absolute paths there). Blocked: {bad or "no absolute path"}. '
                                f'The main agent owns the repository: propose changes as a patch in your workspace.'}
    return call, {'decision': 'allow'}


def main():
    call, out = {}, None
    try:
        call, out = decide(json.loads(sys.stdin.read()))
    except Exception as e:  # fail closed
        out = {'decision': 'deny', 'reason': f'Advisor write guard error: {e!r}'}
    log = os.environ.get('GUARD_LOG')
    if log:
        try:
            with open(log, 'a', encoding='utf-8') as f:
                f.write(json.dumps({'tool': call.get('name'), 'args': {k: (v[:300] if isinstance(v, str) else v)
                                    for k, v in (call.get('args') or {}).items() if k.lower() != 'content'},
                                    'decision': out['decision'], 'reason': out.get('reason')}) + '\n')
        except Exception:
            pass
    print(json.dumps(out))


main()
