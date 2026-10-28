#!/usr/bin/env bash
# Run a Drupal module through the same container job as
# digitalutsc/reusable_workflows' islandora-module-ci.yml, on this machine.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-module-ci.sh [options] <module-dir>

Runs the islandora-module-ci.yml job for one module checkout: the module is
mounted read-only into ghcr.io/islandora/ci:<drupal>-php<php>, and the image
enables it and runs its tests. One run per Drupal x PHP pair, one at a time.

Options:
  -m NAME   module machine name (default: the *.info.yml basename in <module-dir>)
  -d LIST   Drupal versions, space-separated (default: "10.6 11.3")
  -p LIST   PHP versions, space-separated (default: "8.3 8.4")
  -c        start chromedriver (only FunctionalJavascript tests need it)
  -n        dry run: print the docker commands, run nothing
  -h        this help

Environment:
  CI_IMAGE            image repository (default: ghcr.io/islandora/ci)
  CI_PLATFORM         docker platform, e.g. linux/amd64 like GitHub's runners
                      (default: unset, this machine's; the CI images are multi-arch)
  CHROMEDRIVER_IMAGE  (default: drupalci/webdriver-chromedriver:production)
  COMPOSER_CACHE_VOLUME  named volume mounted as the image's Composer cache
                      (/root/.composer/cache), shared between runs (default: none,
                      every run downloads, as on GitHub)
  LOG_DIR             per-run logs (default: ./logs)
EOF
}

die() { echo "error: $*" >&2; exit 2; }

module_name=""
drupal_versions="10.6 11.3"
php_versions="8.3 8.4"
chromedriver=false
dry_run=false

while getopts "m:d:p:cnh" opt; do
  case "$opt" in
    m) module_name="$OPTARG" ;;
    d) drupal_versions="$OPTARG" ;;
    p) php_versions="$OPTARG" ;;
    c) chromedriver=true ;;
    n) dry_run=true ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || { usage >&2; exit 2; }

module_dir="$(cd "$1" 2>/dev/null && pwd)" || die "no such directory: $1"

if [ -z "$module_name" ]; then
  infos=()
  for f in "$module_dir"/*.info.yml; do
    [ -e "$f" ] && infos+=("$f")
  done
  [ "${#infos[@]}" -eq 1 ] || die "found ${#infos[@]} *.info.yml in $module_dir; pass -m <machine name>"
  module_name="$(basename "${infos[0]}" .info.yml)"
fi

ci_image="${CI_IMAGE:-ghcr.io/islandora/ci}"
platform="${CI_PLATFORM:-}"
platform_args=()
[ -n "$platform" ] && platform_args=(--platform "$platform")
cache_args=()
[ -n "${COMPOSER_CACHE_VOLUME:-}" ] && cache_args=(--volume "$COMPOSER_CACHE_VOLUME:/root/.composer/cache")
chromedriver_image="${CHROMEDRIVER_IMAGE:-drupalci/webdriver-chromedriver:production}"
log_dir="${LOG_DIR:-$PWD/logs}"

# The workflow uses fixed names (network ci-default, containers drupal and
# chromedriver). Suffix them with the PID so runs can't collide, and keep the
# fixed names as network aliases so the containers still find each other.
run_id="lga-$$"
network="$run_id-net"

# Dry-run output goes to stderr so a caller's >/dev/null doesn't hide it.
run() {
  if $dry_run; then
    { printf '+'; printf ' %q' "$@"; printf '\n'; } >&2
  else
    "$@"
  fi
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  $dry_run && return
  docker ps -aq --filter "name=^$run_id-" | xargs docker rm -f >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Module $module_name from $module_dir"
echo "Image $ci_image (${platform:-native}); Drupal: $drupal_versions; PHP: $php_versions; chromedriver: $chromedriver"
$dry_run || mkdir -p "$log_dir"

run docker network create "$network" >/dev/null

if $chromedriver; then
  run docker run -d \
    --name "$run_id-chromedriver" \
    --network "$network" --network-alias chromedriver \
    ${platform_args[@]+"${platform_args[@]}"} \
    "$chromedriver_image" \
    chromedriver --log-path=/dev/null --verbose --allowed-ips= --allowed-origins='*' >/dev/null
fi

results=()
failed=0
for drupal in $drupal_versions; do
  for php in $php_versions; do
    tag="$drupal-php$php"
    log="$log_dir/$module_name-$tag.log"
    echo
    echo "=== PHP $php | Drupal $drupal  (log: $log)"
    cmd=(docker run --rm
      --name "$run_id-drupal-$tag"
      --hostname drupal
      --network "$network" --network-alias drupal
      ${platform_args[@]+"${platform_args[@]}"}
      ${cache_args[@]+"${cache_args[@]}"}
      --volume "$module_dir:/var/www/drupal/web/modules/contrib/$module_name:ro"
      --env "ENABLE_MODULES=$module_name"
      "$ci_image:$tag")
    if $dry_run; then
      run "${cmd[@]}"
      continue
    fi
    start=$SECONDS
    if "${cmd[@]}" 2>&1 | tee "$log"; then
      results+=("PASS  PHP $php | Drupal $drupal  ($((SECONDS - start))s)")
    else
      results+=("FAIL  PHP $php | Drupal $drupal  ($((SECONDS - start))s)  $log")
      failed=1
    fi
  done
done

if ! $dry_run; then
  echo
  echo "=== Summary for $module_name"
  printf '%s\n' "${results[@]}"
fi
exit "$failed"
