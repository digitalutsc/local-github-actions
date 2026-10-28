"""Turn a results TSV (run-act-all.sh / run-direct-all.sh) into Markdown.

Usage: python3 -I lib/report.py <results.tsv> <title>
"""

import collections
import csv
import sys


def main(path, title):
    rows = list(csv.DictReader(open(path), delimiter="\t"))
    reason_col = "failed_step" if rows and "failed_step" in rows[0] else "stage"
    total = len(rows)
    passed = sum(r["result"].startswith("PASS") for r in rows)
    no_tests = sum(r["result"] == "PASS (0 tests)" for r in rows)

    by_module = collections.OrderedDict()
    for r in rows:
        by_module.setdefault(r["module"], []).append(r)
    modules_green = sum(all(r["result"].startswith("PASS") for r in rs) for rs in by_module.values())

    out = [f"# {title}", ""]
    out.append(f"- Source: `{path.split('/')[-1]}`")
    out.append(f"- Jobs: {total}, passed {passed} (of which {no_tests} ran 0 tests), failed {total - passed}")
    out.append(f"- Modules: {len(by_module)}, all jobs green in {modules_green}")
    out.append("")

    reasons = collections.Counter(r[reason_col] for r in rows if not r["result"].startswith("PASS"))
    if reasons:
        out += ["## Failures by cause", "", "| Cause | Jobs |", "| --- | --- |"]
        out += [f"| {k or '(unknown)'} | {v} |" for k, v in reasons.most_common()]
        out.append("")

    out += ["## Per module", "", "| Module | Passed | Failing combinations and cause |", "| --- | --- | --- |"]
    for module, rs in by_module.items():
        ok = sum(r["result"].startswith("PASS") for r in rs)
        empty = " (0 tests)" if rs and all(r["result"] == "PASS (0 tests)" for r in rs) else ""
        fails = "; ".join(f"`{r['combination']}`: {r[reason_col]} ([log]({r['log']}))"
                          for r in rs if not r["result"].startswith("PASS"))
        out.append(f"| {module} | {ok}/{len(rs)}{empty} | {fails or '—'} |")
    out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
