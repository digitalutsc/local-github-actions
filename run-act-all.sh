#!/usr/bin/env bash
# Pass A: run each module's own .github/workflows/ci.yml with act, with
# digitalutsc/reusable_workflows replaced by the local clone (the branch under
# test), one matrix combination at a time.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-act-all.sh [module-dir ...]

Default: every directory under modules/ that has .github/workflows/ci.yml.

For each module and each matrix combination of the reusable workflow it calls:
removes the workflow's fixed-name leftovers (network ci-default, containers
drupal and chromedriver; GitHub gets a fresh VM per job, this machine doesn't),
runs `act workflow_dispatch` filtered to that combination, and records the
result and the first failing step.

Output: logs/act/<branch>/<module>/<combination>.log, results/act-<stamp>.tsv and .md.

Environment:
  REUSABLE_DIR      clone of the branch under test (default: ./reusable_workflows)
  ACT_RUNNER_IMAGE  default: catthehacker/ubuntu:act-24.04
  ACT_ARCH          container architecture (default: this machine's, linux/arm64 here)
EOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

here="$(cd "$(dirname "$0")" && pwd)"
reusable_dir="$(cd "${REUSABLE_DIR:-$here/reusable_workflows}" 2>/dev/null && pwd)" \
  || { echo "error: no reusable_workflows clone; run make reusable" >&2; exit 2; }
runner_image="${ACT_RUNNER_IMAGE:-catthehacker/ubuntu:act-24.04}"
arch="${ACT_ARCH:-linux/$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')}"
command -v act >/dev/null 2>&1 || { echo "error: act is not installed (brew install act)" >&2; exit 2; }
python3 -I -c 'import yaml' 2>/dev/null \
  || { echo "error: python3 needs PyYAML to read the workflows (python3 -m pip install pyyaml)" >&2; exit 2; }

if [ $# -gt 0 ]; then
  modules=("$@")
  for d in "${modules[@]}"; do
    [ -d "$d" ] || { echo "error: $d not found; copy it first: make modules MODULES=$(basename "$d")" >&2; exit 2; }
  done
else
  modules=()
  for d in "$here"/modules/*/; do
    [ -f "$d.github/workflows/ci.yml" ] && modules+=("${d%/}")
  done
fi
[ "${#modules[@]}" -gt 0 ] || { echo "error: no modules; run make modules" >&2; exit 2; }

stamp="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$here/results"
tsv="$here/results/act-$stamp.tsv"
branch="$(git -C "$reusable_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
ref="$branch@$(git -C "$reusable_dir" rev-parse --short HEAD 2>/dev/null || echo '?')"
# Logs per branch, so testing one branch doesn't overwrite another's.
branch_label="$(printf '%s' "$branch" | tr -c '[:alnum:]._-' '_')"
printf 'module\tworkflow\tcombination\tresult\tfailed_step\tseconds\tlog\n' > "$tsv"

cleanup_fixed_names() {
  docker rm -f drupal chromedriver >/dev/null 2>&1 || true
  docker network rm ci-default >/dev/null 2>&1 || true
}

echo "Branch under test: $ref ($reusable_dir)"
echo "Modules: ${#modules[@]}; results: $tsv"

for module_dir in "${modules[@]}"; do
  module_dir="$(cd "$module_dir" && pwd)"
  module="$(basename "$module_dir")"
  ci="$module_dir/.github/workflows/ci.yml"
  log_dir="$here/logs/act/$branch_label/$module"
  mkdir -p "$log_dir"

  lines="$(python3 -I "$here/lib/matrix.py" "$ci" "$reusable_dir")" || {
    printf '%s\t-\t-\tERROR\tcould not read matrix\t0\t-\n' "$module" >> "$tsv"; continue; }
  [ -n "$lines" ] || { printf '%s\t-\t-\tSKIP\tno reusable_workflows job\t0\t-\n' "$module" >> "$tsv"; continue; }

  while IFS=$'\t' read -r job workflow combo; do
    filters=()
    if [ "$combo" = "*" ]; then
      label="all"
    else
      label="$(printf '%s' "$combo" | sed 's/ /_/g; s/:/-/g; s/\^/v/g' | tr -cd '[:alnum:]._-')"
      for kv in $combo; do filters+=(--matrix "$kv"); done
    fi
    log="$log_dir/$label.log"
    echo
    echo "=== $module [$workflow] $combo"
    cleanup_fixed_names
    start=$SECONDS
    set +e
    (cd "$module_dir" && act workflow_dispatch \
        -W .github/workflows/ci.yml -j "$job" \
        --bind --rm --container-architecture "$arch" --pull=false \
        -P "ubuntu-latest=$runner_image" -P "ubuntu-24.04=$runner_image" \
        --local-repository "digitalutsc/reusable_workflows@main=$reusable_dir" \
        ${filters[@]+"${filters[@]}"}) > "$log" 2>&1 < /dev/null
    status=$?
    set -e
    secs=$((SECONDS - start))
    failed_step="$(grep -o '❌  Failure - Main [^[]*' "$log" | head -1 | sed 's/❌  Failure - Main //; s/[[:space:]]*$//' || true)"
    if [ "$status" -eq 0 ] && grep -q '🏁  Job succeeded' "$log"; then
      result=PASS
      grep -qE 'Test Suite Loaded \(0 tests\)|No tests executed' "$log" && result="PASS (0 tests)"
    else
      result=FAIL
      [ -n "$failed_step" ] || failed_step="(act exit $status; see log)"
    fi
    echo "    $result ${failed_step:+- $failed_step }(${secs}s)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$module" "$workflow" "$combo" "$result" "$failed_step" "$secs" "${log#"$here"/}" >> "$tsv"
  done <<< "$lines"
done
cleanup_fixed_names

python3 -I "$here/lib/report.py" "$tsv" "Pass A: module CI with act, reusable_workflows $ref" > "${tsv%.tsv}.md"
echo
echo "Report: ${tsv%.tsv}.md"
