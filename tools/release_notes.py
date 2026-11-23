#!/usr/bin/env python3
"""A release's notes on GitHub: tools/release_notes.md, with the version, its channel and what it brought (its entry
in CHANGELOG.md) filled in. The release workflow (.github/workflows/release.yml) runs it.

    tools/release_notes.py 0.2.0             the notes
    tools/release_notes.py 0.2.0 --channel   "Stable" or "Preview", as CHANGELOG.md has it

It fails if CHANGELOG.md has no entry for the version, so a release is never made without one.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def entry(version):
    text = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    m = re.search(r"^## %s\n\n\*\*(Stable|Preview)\*\* · ([^\n]+)\n(.*?)(?=^## |\Z)" % re.escape(version), text, re.M | re.S)
    if not m:
        sys.exit("CHANGELOG.md has no entry for %s: add one (## %s, then **Stable** or **Preview** · its date) before releasing it" % (version, version))
    return m.group(1), m.group(2).strip(), m.group(3).strip()


def unwrapped(text):
    """The lines wrapped at 120 characters joined again: GitHub's release notes may show each line break as one."""
    out = []
    for line in text.split("\n"):
        starts = re.match(r"\s*([-*]|\d+\.|#|\||`)", line)
        if out and out[-1].strip() and line.strip() and not starts:
            out[-1] = out[-1].rstrip() + " " + line.strip()
        else:
            out.append(line)
    return "\n".join(out)


def main():
    version = sys.argv[1]
    channel, date, changes = entry(version)
    if "--channel" in sys.argv:
        print(channel)
        return
    about = ("**Stable** · %s. The version to use for playing and recording." % date if channel == "Stable" else
             "**Preview** · %s. The newest features first, before they have been played as long: the Stable version is the "
             "latest release that isn't marked Pre-release." % date)
    notes = (ROOT / "tools" / "release_notes.md").read_text(encoding="utf-8")
    print(unwrapped(notes.replace("{{version}}", version).replace("{{channel}}", about).replace("{{changes}}", changes)), end="")


if __name__ == "__main__":
    main()
