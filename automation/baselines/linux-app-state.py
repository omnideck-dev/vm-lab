#!/usr/bin/env python3
"""Inspect or clear exact omnideck configuration paths in a disposable lab home."""

import argparse
import os
from pathlib import Path
import pwd
import shutil
import sys


APP_CONFIG_NAMES = ("omnideck", "omnideck-cli")


def app_paths(home):
    home = Path(home)
    if not home.is_absolute():
        raise ValueError("Tester home must be an absolute path")
    home = home.resolve(strict=True)
    if home == Path("/") or not home.is_dir():
        raise ValueError("Tester home must be an existing non-root directory")
    config = home / ".config"
    try:
        config.lstat()
    except FileNotFoundError:
        return []
    if config.is_symlink() or not config.is_dir():
        raise ValueError(f"Refusing unexpected configuration parent: {config}")
    # Open the directory so an unreadable parent cannot look like absent state.
    with os.scandir(config):
        pass
    present = []
    for name in APP_CONFIG_NAMES:
        path = config / name
        try:
            path.lstat()
        except FileNotFoundError:
            continue
        present.append(path)
    return present


def check(home):
    present = app_paths(home)
    if present:
        raise ValueError("Saved omnideck state remains: " + ", ".join(map(str, present)))


def clean(home):
    for path in app_paths(home):
        # An app leaf may be a dangling link. Remove the link, never its target.
        if path.is_symlink() or not path.is_dir():
            path.unlink()
        else:
            shutil.rmtree(path)
        print(f"Removed disposable app state: {path}")
    check(home)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "clean"))
    parser.add_argument("--home", help="Tester home; defaults to the tester account's home")
    args = parser.parse_args()
    try:
        home = args.home or pwd.getpwnam("tester").pw_dir
        if args.action == "clean":
            clean(home)
        else:
            check(home)
    except (OSError, ValueError, KeyError) as error:
        print(f"Linux baseline app-state verification failed: {error}", file=sys.stderr)
        return 1
    print("Linux baseline has no saved omnideck configuration")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
