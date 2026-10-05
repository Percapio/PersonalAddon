"""The verdict and the report (Architecture/20261002-Phase10.md section 6.2)."""
import datetime

from . import premises as premise_module
from . import surface as surface_module

PASS = "Pass"
REVIEW = "Review"
FAIL = "Fail"
EXIT_CODES = {PASS: 0, FAIL: 1, REVIEW: 2}


def judge(report):
    """The verdict, from the most severe finding; each reason names its source."""
    fail, review = [], []
    for item in report["premises"]:
        if item["status"] in (premise_module.BROKEN, premise_module.UNKNOWN):
            fail.append(f"premise {item['id']}: {item['status']} ({item['evidence']})")
        elif item["status"] == premise_module.NEEDS_REVIEW:
            review.append(f"premise {item['id']}: {', '.join(item['changedFiles'])} changed")
    for item in report["surface"]:
        if item["change"] == surface_module.GONE:
            fail.append(f"surface {item['name']}: Gone")
        elif item["change"] in (surface_module.APPEARED, surface_module.MOVED, surface_module.FLAGS_CHANGED):
            review.append(f"surface {item['name']}: {item['change']}")
    lint = report["lint"]
    if lint["hits"] or lint["stale"]:
        fail.append(f"lint: {len(lint['hits'])} hit(s), {len(lint['stale'])} stale allowlist entr(y/ies)")
    for error in report["docsParseErrors"]:
        fail.append(f"docs unreadable: {error}")
    for tag in report["loadSet"]["unknownTags"]:
        review.append(f"unknown TOC tag {tag}")
    for missing in report["loadSet"]["missingFiles"]:
        review.append(f"listed but absent: {missing}")
    if report["degraded"]:
        review.append("degraded check: the baseline copy is missing, so there are no line diffs")
    if fail:
        return {"kind": FAIL, "reasons": fail + review}
    if review:
        return {"kind": REVIEW, "reasons": review}
    return {"kind": PASS, "reasons": []}


def _when(seconds):
    return datetime.datetime.fromtimestamp(seconds).strftime("%Y-%m-%d %H:%M:%S")


def _budgeted(lines, budget):
    if len(lines) <= budget:
        return lines, 0
    return lines[:budget], len(lines) - budget


def render_markdown(report, config):
    """The versioned report, in section 6.2's order."""
    per_file = config["report"]["diff_lines_per_file"]
    per_report = config["report"]["diff_lines_per_report"]
    per_kind = config["report"]["docs_changes_per_kind"]
    verdict = report["verdict"]
    out = [f"# Patch check: {report['client']['label']}", ""]
    out.append(f"**Verdict: {verdict['kind']}.** Checked {_when(report['checkedAt'])}.")
    out.append("")
    out.append(f"- Client: build {report['client']['build'] or 'unreadable'}; `WowB.exe` of "
               f"{_when(report['client']['binaryModifiedAt'])}"
               + (f" ({report['buildNote']}; clients compared by file time)" if report["buildNote"] else ""))
    out.append(f"- Baseline: {report['baseline']['label']}"
               + (" (degraded: the store's copy is missing)" if report["degraded"] else ""))
    out.append(f"- Export: exported {_when(report['exportedAt'])}; digest `{report['exportDigest'][:16]}`")
    if verdict["reasons"]:
        out += ["", "**Reasons:**"] + [f"- {reason}" for reason in verdict["reasons"]]

    out += ["", "## Premises", "", "| Id | Outcome | Evidence | If it stops holding |", "|---|---|---|---|"]
    for item in report["premises"]:
        consequence = item["consequence"] if item["status"] != premise_module.HOLDS else ""
        out.append(f"| `{item['id']}` | {item['status']} | {item['evidence']} | {consequence} |")

    changed = [item for item in report["surface"] if item["change"] != surface_module.UNCHANGED]
    out += ["", "## Surface changes", ""]
    out.append(f"{report['surfaceCounts']['total']} names on the surface; {len(changed)} changed.")
    if changed:
        out += ["", "| Name | Change | Detail | Used at |", "|---|---|---|---|"]
        for item in changed:
            out.append(f"| `{item['name']}` | {item['change']} | {item['detail']} | {', '.join(item['usedAt'][:2])} |")

    out += ["", "## Watched files", ""]
    if not report["watched"]:
        out.append("None changed.")
    else:
        out += ["| File | Change | Lines added | Lines removed |", "|---|---|---|---|"]
        for item in report["watched"]:
            out.append(f"| `{item['file']}` | {item['change']} | {item.get('added', '')} | {item.get('removed', '')} |")
        remaining = per_report
        for item in report["watched"]:
            diff = item.get("diff") or []
            if not diff or remaining <= 0:
                continue
            shown, cut = _budgeted(diff, min(per_file, remaining))
            remaining -= len(shown)
            out += ["", f"**`{item['file']}`**", "", "```diff"] + shown + ["```"]
            if cut:
                out.append(f"{cut} more line(s) in the store's full diff.")
        if any(item.get("diff") for item in report["watched"]) and remaining <= 0:
            out.append("")
            out.append("The report's diff budget is spent; the store keeps every diff in full.")

    lint = report["lint"]
    out += ["", "## Secret-read lint, against the current docs", ""]
    out.append(f"{len(lint['hits'])} hit(s), {lint['allowlisted']} allowlisted, {len(lint['stale'])} stale. "
               f"Secret-capable: {', '.join(str(size) for size in lint['sizes'])} "
               "(global, namespaced, widget methods, events).")
    for hit in lint["hits"]:
        out.append(f"- HIT `{hit}`")
    for stale in lint["stale"]:
        out.append(f"- STALE `{stale}`")

    out += ["", "## The export", ""]
    if report["degraded"]:
        out.append("Not compared: the baseline copy is missing.")
    else:
        out.append(f"{len(report['exportAdded'])} added, {len(report['exportRemoved'])} removed, "
                   f"{report['exportModifiedCount']} modified.")
        for label, files in (("Added", report["exportAdded"]), ("Removed", report["exportRemoved"])):
            for file in files:
                out.append(f"- {label}: `{file}`")

    out += ["", "## Documented entries", ""]
    if report["degraded"]:
        out.append("Not compared: the baseline copy is missing.")
    else:
        for label, names in (("Added", report["docsAdded"]), ("Removed", report["docsRemoved"]),
                             ("Flags changed", report["docsFlagsChanged"])):
            shown, cut = _budgeted(names, per_kind)
            out.append(f"- {label} ({len(names)}): " + (", ".join(f"`{name}`" for name in shown) or "none")
                       + (f", and {cut} more" if cut else ""))

    loaded = report["loadSet"]
    out += ["", "## Load set", ""]
    out.append(f"{loaded['files']} files load on this client. Unknown tags: {len(loaded['unknownTags'])}. "
               f"Listed but absent: {len(loaded['missingFiles'])}.")
    for tag in loaded["unknownTags"]:
        out.append(f"- Unknown tag: {tag}")
    for missing in loaded["missingFiles"]:
        out.append(f"- Listed but absent: {missing}")
    out.append("")
    return "\n".join(out)
