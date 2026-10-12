"""Detached Strata entry point. Uses the installed Strata Python environment."""
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 aktsmm
import argparse
import os
from pathlib import Path
import runpy
import sys
import traceback


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--config', required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--stdout', required=True)
    parser.add_argument('--stderr', required=True)
    args = parser.parse_args()
    # No parent console or pipe is used after detaching. Native subprocesses
    # inherit these log handles too, including errors from the Strata engine.
    with open(os.devnull, 'r') as incoming, open(args.stdout, 'a', encoding='utf-8', buffering=1) as outgoing, open(args.stderr, 'a', encoding='utf-8', buffering=1) as errors:
        os.dup2(incoming.fileno(), 0)
        os.dup2(outgoing.fileno(), 1)
        os.dup2(errors.fileno(), 2)
        sys.stdin, sys.stdout, sys.stderr = incoming, outgoing, errors
        root = Path(args.root).resolve()
        os.chdir(root)
        server = root / 'serve' / 'server.py'
        sys.path.insert(0, str(server.parent))
        sys.argv = [str(server), '--engine', 'strata', '--config', args.config,
                    '--host', '127.0.0.1', '--port', str(args.port)]
        try:
            runpy.run_path(str(server), run_name='__main__')
        except SystemExit as error:
            if error.code is None:
                return 0
            if isinstance(error.code, int):
                return error.code
            print(error.code, file=sys.stderr)
            return 1
        except Exception:
            traceback.print_exc(file=sys.stderr)
            return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
