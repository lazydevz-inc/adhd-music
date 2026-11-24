"""Runs dmgbuild with the macOS 26.2 background fix.

dmgbuild 1.6.5 (the last version that runs on this Mac's Python 3.9) also writes a Finder bookmark
for the background picture, and Finder on macOS 26.2+ then shows no background at all. dmgbuild 1.6.7
fixed it by not writing that bookmark (dmgbuild PR #275); this does the same, then runs dmgbuild as usual.
Usage: same arguments as the dmgbuild command.
"""
import sys

import dmgbuild.core
from dmgbuild.__main__ import main

dmgbuild.core.Bookmark.for_file = staticmethod(lambda *args, **kwargs: None)

if __name__ == "__main__":
    sys.exit(main())
