#!/usr/bin/env bash
# Run reusable_workflows' workflow files themselves with act
# (https://github.com/nektos/act), against the local clone.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-act.sh selftest [act args...]
       run-act.sh module <module-dir> [act args...]

  selftest  reusable_workflows' testing.yml, which calls
            islandora-module-ci.yml through ./ (your working copy).
  module    a module's .github/workflows/ci.yml; its
            digitalutsc/reusable_workflows@main reference is replaced by
            the local clone, so it runs your working copy too.

Extra arguments go to act (e.g. -j islandora-module-ci, --list, -n).

Environment:
  REUSABLE_DIR     local reusable_workflows clone (default: ./reusable_workflows,
                   made by `make reusable`)
  REUSABLE_REF     ref the module workflows call (default: main)
  ACT_RUNNER_IMAGE image for runs-on: ubuntu-24.04 / ubuntu-latest
                   (default: catthehacker/ubuntu:act-24.04)
  ACT_ARCH         container architecture (default: this machine's)

act ignores permissions: and concurrency:, and doesn't reproduce how GitHub
resolves remote reusable workflows; check those on GitHub.
EOF
}

die() { echo "error: $*" >&2; exit 2; }

command -v act >/dev/null 2>&1 || die "act is not installed (macOS: brew install act)"

here="$(cd "$(dirname "$0")" && pwd)"
reusable_dir="$(cd "${REUSABLE_DIR:-$here/reusable_workflows}" 2>/dev/null && pwd)" \
  || die "reusable_workflows clone not found; run make reusable or set REUSABLE_DIR"
reusable_ref="${REUSABLE_REF:-main}"
runner_image="${ACT_RUNNER_IMAGE:-catthehacker/ubuntu:act-24.04}"
platform="${ACT_ARCH:-linux/$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')}"

# --bind mounts the checkout at its real path, so the job's own
# `docker run --volume "$PWD:..."` (sent to this machine's Docker through the
# socket act mounts) points at a directory that exists here.
common=(--bind --rm
  --container-architecture "$platform"
  -P "ubuntu-24.04=$runner_image"
  -P "ubuntu-latest=$runner_image")

[ $# -ge 1 ] || { usage >&2; exit 2; }
mode="$1"; shift
case "$mode" in
  selftest)
    cd "$reusable_dir"
    exec act push -W .github/workflows/testing.yml "${common[@]}" "$@"
    ;;
  module)
    [ $# -ge 1 ] || die "module needs <module-dir>"
    module_dir="$(cd "$1" 2>/dev/null && pwd)" || die "no such directory: $1"
    shift
    [ -f "$module_dir/.github/workflows/ci.yml" ] || die "$module_dir/.github/workflows/ci.yml not found"
    act --help 2>&1 | grep -q -- '--local-repository' \
      || die "this act has no --local-repository; upgrade act to test against the local clone"
    cd "$module_dir"
    exec act workflow_dispatch -W .github/workflows/ci.yml "${common[@]}" \
      --local-repository "digitalutsc/reusable_workflows@$reusable_ref=$reusable_dir" "$@"
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
