"""Print the matrix combinations a module's CI would run.

Usage: python3 -I lib/matrix.py <module-ci.yml> <reusable_workflows dir>

Follows each job's `uses: digitalutsc/reusable_workflows/<path>@<ref>` to the
local clone (and on through wrappers that call another workflow), works out
the called workflow's inputs (the caller's `with:`, else the input's default),
expands strategy.matrix (product, then exclude, then include, as GitHub does)
and prints one line per combination:

    <job id>\t<called file>\t<key>:<value> <key>:<value> ...

Each `key:value` is an act `--matrix` filter. Matrix values may be literal
lists or `${{ fromJSON(inputs.NAME) }}`. Anything else can't be expanded here;
the line then carries `*` and the caller runs the whole matrix in one act run.
"""

import itertools
import json
import re
import sys

import yaml

USES = re.compile(r"^(?:digitalutsc/reusable_workflows/|\./)(?P<path>\.github/workflows/[^@]+)(?:@(?P<ref>.+))?$")
EXPR = re.compile(r"^\$\{\{\s*(?P<e>.*?)\s*\}\}$")
FROM_JSON_INPUT = re.compile(r"fromJSON\(\s*inputs\.(?P<name>[\w-]+)\s*\)")
INPUT = re.compile(r"inputs\.(?P<name>[\w-]+)")


class Unresolvable(Exception):
    pass


def resolve(value, inputs):
    """Evaluate the few expressions a matrix or `with:` value uses here."""
    if not isinstance(value, str):
        return value
    m = EXPR.match(value.strip())
    if not m:
        return value
    e = m["e"]
    if (fj := FROM_JSON_INPUT.fullmatch(e)) and fj["name"] in inputs:
        v = inputs[fj["name"]]
        return json.loads(v) if isinstance(v, str) else v
    if (iv := INPUT.fullmatch(e)) and iv["name"] in inputs:
        return inputs[iv["name"]]
    raise Unresolvable(value)


def declared_inputs(workflow):
    # PyYAML (YAML 1.1) reads the key `on` as the boolean True.
    on = workflow.get("on", workflow.get(True)) or {}
    call = on.get("workflow_call") if isinstance(on, dict) else None
    return (call or {}).get("inputs") or {}


def effective_inputs(workflow, with_):
    out = {}
    for name, spec in declared_inputs(workflow).items():
        if name in with_:
            out[name] = with_[name]
        elif isinstance(spec, dict) and "default" in spec:
            out[name] = spec["default"]
    return out


def combos(matrix, inputs):
    if isinstance(matrix, str):
        matrix = resolve(matrix, inputs)
    if not isinstance(matrix, dict):
        raise Unresolvable(matrix)
    axes = {k: resolve(v, inputs) for k, v in matrix.items() if k not in ("include", "exclude")}
    if any(not isinstance(v, list) for v in axes.values()):
        raise Unresolvable(axes)
    keys = list(axes)
    rows = [dict(zip(keys, vals)) for vals in itertools.product(*axes.values())] if keys else []
    for ex in resolve(matrix.get("exclude"), inputs) or []:
        rows = [r for r in rows if not all(str(r.get(k)) == str(v) for k, v in ex.items())]
    for inc in resolve(matrix.get("include"), inputs) or []:
        # An include that only adds keys extends the rows it matches; one that
        # matches nothing becomes a row of its own.
        matched = False
        for r in rows:
            if all(str(r[k]) == str(v) for k, v in inc.items() if k in keys):
                r.update({k: v for k, v in inc.items() if k not in keys})
                matched = True
        if not matched:
            rows.append(dict(inc))
    return rows


def expand(path, with_, reusable_dir, depth=0):
    """Yield (called file, combination) for every leaf job of a called workflow."""
    if depth > 5:
        raise Unresolvable(f"workflow nesting too deep at {path}")
    workflow = yaml.safe_load(open(f"{reusable_dir}/{path}"))
    inputs = effective_inputs(workflow, with_)
    for job in (workflow.get("jobs") or {}).values():
        if "uses" in job:
            m = USES.match(str(job["uses"]))
            if not m:
                raise Unresolvable(job["uses"])
            nested_with = {k: resolve(v, inputs) for k, v in (job.get("with") or {}).items()}
            yield from expand(m["path"], nested_with, reusable_dir, depth + 1)
            continue
        for row in combos((job.get("strategy") or {}).get("matrix") or {}, inputs) or [{}]:
            yield path, row


def main(caller_path, reusable_dir):
    caller = yaml.safe_load(open(caller_path))
    for job_id, job in (caller.get("jobs") or {}).items():
        m = USES.match(str(job.get("uses", "")))
        if not m or str(job["uses"]).startswith("./"):
            continue
        try:
            for path, row in expand(m["path"], job.get("with") or {}, reusable_dir):
                print(f"{job_id}\t{path}\t" + " ".join(f"{k}:{v}" for k, v in row.items()))
        except Unresolvable:
            print(f"{job_id}\t{m['path']}\t*")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
