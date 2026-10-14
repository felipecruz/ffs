#!/usr/bin/env python3
"""Turn kcov output into a Markdown report for src/.

Used by .github/workflows/ci.yml for the job summary and the pull request
comment.

Reads Cobertura XML by preference: its schema is fixed (it is what Codecov
consumes), whereas kcov's coverage.json has moved between releases and is
written per binary *and* per merge, so picking the wrong one silently yields
an empty report. coverage.json is still accepted as a fallback, with every
field read defensively. A reporting script must not be what fails a build,
so every path here ends in a readable message and exit status 0.

Usage: kcov_report.py <cobertura.xml|coverage.json> [--title T] [--marker M]
"""

import json
import sys
import xml.etree.ElementTree as ET

MARKER = "<!-- ffs-coverage-report -->"


def num(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def is_src(path):
    """kcov reports either shape depending on the format and the build root."""
    return "/src/" in path or path.startswith("src/")


def short(path):
    return "src/" + path.split("/src/")[-1] if "/src/" in path else path


def from_cobertura(path):
    """[(filename, total_lines, covered_lines)] from Cobertura XML."""
    root = ET.parse(path).getroot()
    out = []
    for cls in root.iter("class"):
        name = cls.get("filename") or cls.get("name") or "?"
        lines = [ln for ln in cls.iter("line") if ln.get("number") is not None]
        if not lines:
            continue
        covered = sum(1 for ln in lines if num(ln.get("hits")) > 0)
        out.append((name, float(len(lines)), float(covered)))
    return out


def from_json(path):
    """Same tuples from kcov's coverage.json, tolerating key renames."""
    with open(path) as fh:
        data = json.load(fh)
    out = []
    for f in data.get("files", []):
        if not isinstance(f, dict):
            continue
        name = f.get("file") or f.get("filename") or f.get("path") or "?"
        out.append((name, num(f.get("total_lines")), num(f.get("covered_lines"))))
    return out


def render(rows, title, marker, source):
    src = [r for r in rows if is_src(str(r[0]))]
    total = sum(r[1] for r in src)
    covered = sum(r[2] for r in src)

    out = [marker, "", f"### {title}", ""]
    if not src or total == 0:
        out += [
            "kcov reported no instrumented lines under `src/`.",
            "",
            "That is a tooling problem, not 0% coverage: check the "
            "`--include-pattern` in the workflow and the `What kcov wrote` step.",
        ]
        if rows:
            out += ["", f"kcov recorded {len(rows)} file(s), none under `src/`:", ""]
            out += [f"- `{r[0]}`" for r in rows[:10]]
            if len(rows) > 10:
                out.append(f"- ...and {len(rows) - 10} more")
        return "\n".join(out) + "\n"

    pct = covered / total * 100
    out += [
        f"**{pct:.1f}%** of lines in `src/` ({covered:.0f} of {total:.0f}), "
        f"measured by kcov on the test binary.",
        "",
        "| File | Lines | Covered | Coverage |",
        "|---|---:|---:|---:|",
    ]
    for name, t, c in sorted(src, key=lambda r: short(str(r[0]))):
        out.append(f"| `{short(str(name))}` | {t:.0f} | {c:.0f} | {(c / t * 100) if t else 0:.1f}% |")
    out += [
        f"| **total** | **{total:.0f}** | **{covered:.0f}** | **{pct:.1f}%** |",
        "",
        "Zig has no coverage instrumentation of its own, so these are kcov's "
        "DWARF line counts over the debug test binary: comptime-heavy and "
        "inlined code is attributed unevenly. Treat it as a trend, not a "
        f"target. (Read from {source}.)",
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

    reader = from_cobertura if path.endswith(".xml") else from_json
    try:
        rows = reader(path)
    except Exception as err:  # unreadable, malformed, or an unexpected schema
        print(f"{marker}\n\n### {title}\n\nCould not read kcov output "
              f"`{path}`: {type(err).__name__}: {err}\n")
        return 0
    print(render(rows, title, marker, f"`{path}`"), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
