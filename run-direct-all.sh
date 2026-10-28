#!/usr/bin/env bash
# Pass B: run the workflow's PHPUnit step (the ghcr.io/islandora/ci container)
# directly for every module x Drupal x PHP pair, several at a time. This is what
# the CI reports once nothing fails before that step.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-direct-all.sh [module-dir ...]

Default: every directory under modules/.

Runs run-module-ci.sh once per module x Drupal x PHP pair, JOBS at a time, and
sorts each failure by the stage of the image's entrypoint it stopped in:
phpcs (coding standards), composer (installing the module's composer.json
requirements), phpunit (tests), or other.

Output: logs/direct/<module>-<drupal>-php<php>.log, results/direct-<stamp>.tsv and .md.

Environment:
  DRUPAL  Drupal versions (default: "10.6 11.3")
  PHP     PHP versions (default: "8.3 8.4")
  JOBS    parallel runs (default: 4)
  CI_IMAGE, CI_PLATFORM, COMPOSER_CACHE_VOLUME: passed to run-module-ci.sh
EOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

here="$(cd "$(dirname "$0")" && pwd)"
drupal_versions="${DRUPAL:-10.6 11.3}"
php_versions="${PHP:-8.3 8.4}"
jobs="${JOBS:-4}"

if [ $# -gt 0 ]; then
  modules=("$@")
  for d in "${modules[@]}"; do
    [ -d "$d" ] || { echo "error: $d not found; copy it first: make modules MODULES=$(basename "$d")" >&2; exit 2; }
  done
else
  modules=()
  for d in "$here"/modules/*/; do modules+=("${d%/}"); done
fi
[ "${#modules[@]}" -gt 0 ] || { echo "error: no modules; run make modules" >&2; exit 2; }

stamp="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$here/results" "$here/logs/direct"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The machine name the module's own CI passes (module_name), so e.g.
# drupal_hero_banner runs as hero_banner, like on GitHub.
machine_name() {
  local ci="$1/.github/workflows/ci.yml" name=""
  [ -f "$ci" ] && name="$(sed -n 's/^[[:space:]]*module_name:[[:space:]]*//p' "$ci" | head -1 | tr -d '"'"'"' ')"
  printf '%s' "$name"
}

for module_dir in "${modules[@]}"; do
  module_dir="$(cd "$module_dir" && pwd)"
  name="$(machine_name "$module_dir")"
  for drupal in $drupal_versions; do
    for php in $php_versions; do
      printf '%s\t%s\t%s\t%s\n' "$module_dir" "${name:--}" "$drupal" "$php"
    done
  done
done > "$work/queue"

echo "Runs: $(wc -l < "$work/queue" | tr -d ' '), $jobs at a time"

# One run: writes one TSV row to $work/rows/<n>.
run_one() {
  local module_dir="$1" name="$2" drupal="$3" php="$4" here="$LGA_HERE" work="$LGA_WORK"
  local module log start status secs stage result
  local args=(-d "$drupal" -p "$php")
  [ "$name" != "-" ] && args+=(-m "$name")
  module="$(basename "$module_dir")"
  log="$here/logs/direct/$module-$drupal-php$php.log"
  start=$SECONDS
  set +e
  LOG_DIR="$work/raw-$module-$drupal-$php" "$here/run-module-ci.sh" \
    "${args[@]}" "$module_dir" > "$log" 2>&1 < /dev/null
  status=$?
  set -e
  secs=$((SECONDS - start))
  if [ "$status" -eq 0 ]; then
    result=PASS; stage=""
    grep -qE 'Test Suite Loaded \(0 tests\)|No tests executed' "$log" && result="PASS (0 tests)"
  else
    result=FAIL
    if grep -qE 'Your requirements could not be resolved|Installation failed, reverting|could not be found in any version' "$log"; then
      stage="composer: requirements not installable"
    elif grep -qE '^(FAILURES!|ERRORS!)' "$log"; then
      stage="phpunit: test failures/errors"
    elif grep -q 'Starting test server' "$log" && grep -q 'Running phpunit' "$log"; then
      stage="phpunit: did not complete"
    elif grep -q 'Starting test server' "$log"; then
      stage="composer/test server"
    elif grep -qE 'FOUND [0-9]+ ERRORS?' "$log"; then
      stage="phpcs: coding standard errors"
    else
      stage="other (see log)"
    fi
  fi
  printf '%s\tdirect\tdrupal:%s php:%s\t%s\t%s\t%s\t%s\n' \
    "$module" "$drupal" "$php" "$result" "$stage" "$secs" "logs/direct/$module-$drupal-php$php.log" \
    > "$work/rows/$module-$drupal-$php"
  echo "$result  $module  Drupal $drupal | PHP $php  ${stage:+($stage) }${secs}s"
}
export -f run_one
export LGA_HERE="$here" LGA_WORK="$work"
mkdir -p "$work/rows"

tr '\t' '\n' < "$work/queue" | xargs -n 4 -P "$jobs" bash -c 'run_one "$@"' _

tsv="$here/results/direct-$stamp.tsv"
printf 'module\tworkflow\tcombination\tresult\tstage\tseconds\tlog\n' > "$tsv"
cat "$work"/rows/* | sort >> "$tsv"
python3 -I "$here/lib/report.py" "$tsv" "Pass B: islandora/ci container run directly (Drupal $drupal_versions; PHP $php_versions)" > "${tsv%.tsv}.md"
echo
echo "Report: ${tsv%.tsv}.md"
