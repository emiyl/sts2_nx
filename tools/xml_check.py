#!/usr/bin/env python3
"""xml_check.py -- validate every project XML file.

Exists because of a self-inflicted build failure worth not repeating:

    error NETSDK1013: The TargetFramework value '' was not recognized.

The cause was not a missing TargetFramework. It was that `aot/sts2.aot.props`
had stopped being well-formed XML, so MSBuild read nothing out of it and every
property in it came back empty. The error named a downstream symptom, three
steps from the cause.

**XML comments cannot contain `--`.** Not escaped, not doubled, not anywhere
between `<!--` and `-->`. Prose written by anyone who uses em-dashes will
produce them constantly, and this project's comments are prose-heavy by design.
A trailing `-` immediately before `-->` is illegal for the same reason.

The repo already carried a `scripts/fix-xml-comments.ps1`, which says this has
bitten before.

Run before any build that reads these files.
"""

import pathlib
import re
import sys
import xml.etree.ElementTree as ET

SKIP = {"bin", "obj", ".git", "apk"}


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    problems = 0
    checked = 0

    patterns = ("*.props", "*.csproj", "*.xml", "*.targets")
    files = sorted({f for p in patterns for f in root.rglob(p)})

    for f in files:
        if SKIP & set(f.parts) or any(part.endswith("-apk") for part in f.parts):
            continue
        checked += 1
        text = f.read_text(errors="replace")

        # Report the specific cause first: a generic "not well-formed" message
        # sends you hunting for a broken tag.
        for m in re.finditer(r"<!--(.*?)-->", text, re.S):
            body = m.group(1)
            line = text[: m.start()].count("\n") + 1
            if "--" in body:
                print(f"{f}:{line}: XML comment contains '--' (illegal)")
                problems += 1
            elif body.endswith("-"):
                print(f"{f}:{line}: XML comment ends with '-' before '-->' (illegal)")
                problems += 1

        # An unterminated comment swallows everything after it, which is the
        # quiet version of the same failure.
        if text.count("<!--") != text.count("-->"):
            print(f"{f}: unbalanced comment markers "
                  f"({text.count('<!--')} open, {text.count('-->')} close)")
            problems += 1

        try:
            ET.parse(f)
        except ET.ParseError as e:
            print(f"{f}: {e}")
            problems += 1

    print(f"\n{checked} file(s) checked; "
          + ("all well-formed" if not problems else f"{problems} problem(s)"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
