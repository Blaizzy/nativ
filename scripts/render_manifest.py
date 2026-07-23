#!/usr/bin/env python3
"""Render Nativ's capability manifest (nativ.yml) into human-readable docs.

nativ.yml is the single source of truth. SUPPORT_MATRIX.md, ROADMAP.md, and
CHANGELOG.md are generated from it and must never be edited by hand.

Usage:
  scripts/render_manifest.py           # write the three generated docs
  scripts/render_manifest.py --check   # validate the manifest and fail on drift
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "nativ.yml"
GENERATED = "<!-- Generated from nativ.yml by scripts/render_manifest.py. Do not edit by hand. -->"

STATUS_ORDER = ["shipped", "experimental", "planned", "exploratory"]
STATUS_LABEL = {
    "shipped": "Shipped",
    "experimental": "Experimental",
    "planned": "Planned",
    "exploratory": "Exploratory",
}


def load():
    with open(MANIFEST) as f:
        return yaml.safe_load(f)


def validate(m):
    errs = []
    caps = m.get("capabilities", [])
    issues = m.get("issues", [])

    cap_ids = set()
    for c in caps:
        for k in ("id", "title", "status"):
            if k not in c:
                errs.append(f"capability missing '{k}': {c.get('id', c)}")
        if c.get("status") not in STATUS_ORDER:
            errs.append(f"capability '{c.get('id')}': invalid status '{c.get('status')}'")
        if c.get("id") in cap_ids:
            errs.append(f"duplicate capability id '{c.get('id')}'")
        cap_ids.add(c.get("id"))
        for t in c.get("tasks", []):
            if "done" not in t or "text" not in t:
                errs.append(f"capability '{c.get('id')}': malformed task {t}")

    nums = set()
    for i in issues:
        if "number" not in i:
            errs.append(f"issue missing 'number': {i}")
        if i.get("number") in nums:
            errs.append(f"duplicate issue #{i.get('number')}")
        nums.add(i.get("number"))

    for c in caps:
        for n in c.get("issues", []):
            if n not in nums:
                errs.append(f"capability '{c['id']}' references missing issue #{n}")
    for i in issues:
        if i.get("capability") and i["capability"] not in cap_ids:
            errs.append(f"issue #{i['number']} references missing capability '{i['capability']}'")
        for edge in ("depends_on", "children"):
            for n in i.get(edge, []):
                if n not in nums:
                    errs.append(f"issue #{i['number']} {edge} references missing #{n}")
        if i.get("part_of") and i["part_of"] not in nums:
            errs.append(f"issue #{i['number']} part_of references missing #{i['part_of']}")
    return errs


def _task_progress(cap):
    tasks = cap.get("tasks", [])
    if not tasks:
        return None
    done = sum(1 for t in tasks if t.get("done"))
    return done, len(tasks)


def render_support_matrix(m):
    repo = m["meta"]["repo"]
    lines = [
        "# Nativ — Feature Support Matrix",
        "",
        GENERATED,
        "",
        "Status: **Shipped** (in the current release) · **Experimental** (usable but "
        "unstable / in active development) · **Planned** (committed) · **Exploratory** "
        "(under investigation).",
        "",
        "## Capabilities",
        "",
        "| Capability | Status | Provider | Notes |",
        "| --- | --- | --- | --- |",
    ]
    caps = sorted(
        m["capabilities"],
        key=lambda c: (STATUS_ORDER.index(c["status"]), c["title"].lower()),
    )
    for c in caps:
        status = STATUS_LABEL[c["status"]]
        prog = _task_progress(c)
        if prog:
            status += f" ({prog[0]}/{prog[1]})"
        issues = " ".join(f"#{n}" for n in c.get("issues", []))
        note = c.get("note", "")
        if issues:
            note = f"{note} ({issues})" if note else issues
        lines.append(f"| {c['title']} | {status} | {c.get('provider', '')} | {note} |")

    lines += ["", "## Runtime providers", "", "| Provider | Role | Version | Repo |", "| --- | --- | --- | --- |"]
    for name, p in m["meta"]["providers"].items():
        version = p.get("version") or "—"
        repo_ref = p.get("repo", "")
        lines.append(f"| {name} | {p.get('role', '')} | `{version}` | {repo_ref} |")

    plat = m["meta"]["platform"]
    lines += [
        "",
        "## Platform",
        "",
        f"- Apple silicon: **{plat.get('apple_silicon', 'required')}** (M1 or later)",
        f"- Minimum macOS: **{plat.get('macos_min')}**",
        "",
        f"See [ROADMAP.md](ROADMAP.md) for planned work and [CHANGELOG.md](CHANGELOG.md) "
        f"for release history. Tracked in [{repo} issues](https://github.com/{repo}/issues).",
        "",
    ]
    return "\n".join(lines)


def render_roadmap(m):
    repo = m["meta"]["repo"]
    caps = m["capabilities"]
    lines = [
        "# Nativ — Roadmap",
        "",
        GENERATED,
        "",
        "Committed and exploratory work, rendered from `nativ.yml`. Shipped capabilities "
        "are in [SUPPORT_MATRIX.md](SUPPORT_MATRIX.md).",
        "",
    ]

    for status in ("experimental", "planned", "exploratory"):
        group = [c for c in caps if c["status"] == status]
        if not group:
            continue
        lines += [f"## {STATUS_LABEL[status]}", ""]
        for c in sorted(group, key=lambda c: c["title"].lower()):
            refs = " ".join(f"#{n}" for n in c.get("issues", []))
            head = f"### {c['title']}"
            if refs:
                head += f" ({refs})"
            lines.append(head)
            if c.get("note"):
                lines += ["", c["note"]]
            tasks = c.get("tasks", [])
            if tasks:
                lines.append("")
                for t in tasks:
                    box = "x" if t.get("done") else " "
                    lines.append(f"- [{box}] {t['text']}")
            lines.append("")

    lines += ["## Backlog by area", ""]
    areas = sorted({i.get("area", "other") for i in m["issues"]})
    for area in areas:
        rows = [i for i in m["issues"] if i.get("area", "other") == area]
        lines += [f"### {area}", ""]
        for i in sorted(rows, key=lambda i: i["number"]):
            edges = []
            if i.get("part_of"):
                edges.append(f"part of #{i['part_of']}")
            if i.get("depends_on"):
                edges.append("depends on " + ", ".join(f"#{n}" for n in i["depends_on"]))
            if i.get("children"):
                edges.append("includes " + ", ".join(f"#{n}" for n in i["children"]))
            suffix = f" _( {'; '.join(edges)} )_" if edges else ""
            lines.append(
                f"- [#{i['number']}](https://github.com/{repo}/issues/{i['number']}) "
                f"{i['title']}{suffix}"
            )
        lines.append("")
    return "\n".join(lines)


def render_changelog(m):
    lines = ["# Changelog", "", GENERATED, ""]
    for rel in m.get("changelog", []):
        header = f"## {rel['version']}"
        if rel.get("date"):
            header += f" — {rel['date']}"
        lines += [header, ""]
        for note in rel.get("notes", []):
            lines.append(f"- {note}")
        lines.append("")
    return "\n".join(lines)


DOCS = {
    "SUPPORT_MATRIX.md": render_support_matrix,
    "ROADMAP.md": render_roadmap,
    "CHANGELOG.md": render_changelog,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="validate + fail on drift instead of writing")
    args = ap.parse_args()

    m = load()
    errs = validate(m)
    if errs:
        print("Manifest validation failed:", file=sys.stderr)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    if args.check:
        stale = []
        for name, fn in DOCS.items():
            want = fn(m).rstrip("\n") + "\n"
            path = ROOT / name
            have = path.read_text() if path.exists() else None
            if have != want:
                stale.append(name)
        if stale:
            print("Generated docs are out of date with nativ.yml:", file=sys.stderr)
            for s in stale:
                print(f"  - {s}", file=sys.stderr)
            print("\nRun: python3 scripts/render_manifest.py", file=sys.stderr)
            sys.exit(1)
        print("Manifest valid and docs in sync.")
        return

    for name, fn in DOCS.items():
        (ROOT / name).write_text(fn(m).rstrip("\n") + "\n")
        print(f"wrote {name}")


if __name__ == "__main__":
    main()
