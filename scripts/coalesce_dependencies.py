#!/usr/bin/env python3
"""Flag issues whose dependencies just completed (Phase 0 — same repo only).

The dependency graph lives in nativ.yml as `depends_on: [<issue number>, ...]`.
An issue's dependency is considered completed when either:

  * that issue is closed on GitHub (`--closed-issue N`), or
  * a manifest edit marks it done (`--previous`/`--current`): the issue was
    removed, or its tracking capability flipped to `shipped`, or that
    capability's task list became fully checked.

For every dependent still open in the manifest, we post one comment saying it is
ready to start. Comments carry a hidden marker so re-runs never duplicate them.

Cross-repo coalescing (labelling issues in mlx-vlm / mlx-audio / mlx-embeddings)
is intentionally out of scope here; it needs the GitHub App and lands in a later
phase.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

MARKER = "<!-- nativ-coalesce:{dep} -->"


def load(path):
    if not path or not os.path.exists(path):
        return None
    with open(path) as f:
        return yaml.safe_load(f) or {}


def _fully_done(cap):
    tasks = cap.get("tasks", [])
    return bool(tasks) and all(t.get("done") for t in tasks)


def completed_from_diff(prev, cur):
    """Issue numbers that a manifest edit marks as completed."""
    if not prev:
        return set()
    done = set()
    prev_nums = {i["number"] for i in prev.get("issues", [])}
    cur_nums = {i["number"] for i in cur.get("issues", [])}
    done |= prev_nums - cur_nums  # removed from the backlog

    prev_caps = {c["id"]: c for c in prev.get("capabilities", [])}
    for c in cur.get("capabilities", []):
        was = prev_caps.get(c["id"])
        if not was:
            continue
        shipped_now = c.get("status") == "shipped" and was.get("status") != "shipped"
        tasks_now = _fully_done(c) and not _fully_done(was)
        if shipped_now or tasks_now:
            done |= set(c.get("issues", []))
    return done


def dependents(cur, completed):
    """Open manifest issues that depend on any completed issue."""
    out = []
    for i in cur.get("issues", []):
        blockers = set(i.get("depends_on", [])) & completed
        if blockers:
            out.append((i, sorted(blockers)))
    return out


def _run(args, **kw):
    return subprocess.run(args, text=True, capture_output=True, **kw)


def already_commented(number, dep, repo):
    marker = MARKER.format(dep=dep)
    r = _run(["gh", "issue", "view", str(number), "-R", repo, "--json", "comments"])
    if r.returncode != 0:
        return False
    try:
        comments = json.loads(r.stdout).get("comments", [])
    except json.JSONDecodeError:
        return False
    return any(marker in (c.get("body") or "") for c in comments)


def comment(number, deps, repo, dry_run):
    for dep in deps:
        if already_commented(number, dep, repo):
            continue
        body = (
            f"{MARKER.format(dep=dep)}\n"
            f"Dependency #{dep} is complete, so this issue is now **ready to start**.\n\n"
            f"_Posted automatically from `nativ.yml`._"
        )
        if dry_run:
            print(f"[dry-run] would comment on #{number} (dependency #{dep})")
            continue
        r = _run(["gh", "issue", "comment", str(number), "-R", repo, "--body", body])
        if r.returncode != 0:
            print(f"failed to comment on #{number}: {r.stderr}", file=sys.stderr)
        else:
            print(f"commented on #{number} (dependency #{dep})")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--current", default="nativ.yml")
    ap.add_argument("--previous", help="prior nativ.yml (push diff)")
    ap.add_argument("--closed-issue", type=int, help="issue number just closed")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "Blaizzy/nativ"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    cur = load(args.current)
    if cur is None:
        sys.exit(f"missing manifest: {args.current}")

    completed = completed_from_diff(load(args.previous), cur)
    if args.closed_issue:
        completed.add(args.closed_issue)

    if not completed:
        print("no completed dependencies; nothing to do.")
        return

    hits = dependents(cur, completed)
    if not hits:
        print(f"completed {sorted(completed)}; no open dependents.")
        return

    for issue, deps in hits:
        comment(issue["number"], deps, args.repo, args.dry_run)


if __name__ == "__main__":
    main()
