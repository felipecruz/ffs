#!/usr/bin/env python3
"""Turn kcov's coverage.json into a Markdown report for src/.

Used by .github/workflows/ci.yml for the job summary and the pull request
comment. kcov writes its numbers as strings and the key set has changed
between releases, so every field is read defensively: a reporting script must
not be what fails a build.

Usage: kcov_report.py <coverage.json> [--marker <html-comment>] [--title <text>]
"""

import json
import sys

MARKER = "<!-- ffs-coverage-report -->"


def num(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def short(path):
    """`/home/runner/work/ffs/ffs/src/match.zig` -> `src/match.zig`."""
    return "src/" + path.split("/src/")[-1] if "/src/" in path else path


def report(data, title, marker):
    files = [f for f in data.get("files", []) if isinstance(f, dict)]
    covered = sum(num(f.get("covered_lines")) for f in files)
    total = sum(num(f.get("total_lines")) for f in files)

    out = [marker, "", f"### {title}", ""]
    if not files or total == 0:
        out += [
            "kcov reported no instrumented lines under `src/`.",
            "",
            "That is a tooling problem, not 0% coverage: check the "
            "`--include-pattern` in the workflow and the `What kcov wrote` step.",
        ]
        return "\n".join(out) + "\n"

    pct = num(data.get("percent_covered"), covered / total * 100)
    out += [
        f"**{pct:.1f}%** of lines in `src/` "
        f"({covered:.0f} of {total:.0f}), measured by kcov on the test binary.",
        "",
        "| File | Lines | Covered | Coverage |",
        "|---|---:|---:|---:|",
    ]
    for f in sorted(files, key=lambda f: short(f.get("file", ""))):
        c, t = num(f.get("covered_lines")), num(f.get("total_lines"))
        file_pct = num(f.get("percent_covered"), (c / t * 100) if t else 0.0)
        out.append(f"| `{short(f.get('file', '?'))}` | {t:.0f} | {c:.0f} | {file_pct:.1f}% |")
    out += [
        f"| **total** | **{total:.0f}** | **{covered:.0f}** | **{pct:.1f}%** |",
        "",
        "Zig has no coverage instrumentation of its own, so these are kcov's "
        "DWARF line counts over the debug test binary: comptime-heavy and "
        "inlined code is attributed unevenly. Treat it as a trend, not a target.",
    ]
    return "\n".join(out) + "\n"


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    path, title, marker = argv[1], "Line coverage", MARKER
    for i, arg in enumerate(argv):
        if arg == "--title" and i + 1 < len(argv):
            title = argv[i + 1]
        if arg == "--marker" and i + 1 < len(argv):
            marker = argv[i + 1]
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError) as err:
        print(f"{marker}\n\n### {title}\n\nCould not read kcov output: {err}\n")
        return 0
    print(report(data, title, marker), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
