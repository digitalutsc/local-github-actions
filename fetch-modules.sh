#!/usr/bin/env bash
# Copy every contrib module whose GitHub workflows call
# digitalutsc/reusable_workflows out of a running isle-lite replica into
# modules/<dir>, each as a one-commit git repository (act reads the commit and
# ref from git; without one it still runs but logs errors on every step).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: fetch-modules.sh [module-dir-name ...]

Default: all contrib modules in the replica whose .github/workflows/*.yml
reference digitalutsc/reusable_workflows.

Environment:
  SITE       replica to copy from (default: stories; container isle-lite-drupal-$SITE-1)
  CONTAINER  container name, overrides SITE
EOF
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

here="$(cd "$(dirname "$0")" && pwd)"
container="${CONTAINER:-isle-lite-drupal-${SITE:-stories}-1}"
contrib=/var/www/drupal/web/modules/contrib

docker inspect "$container" >/dev/null 2>&1 \
  || { echo "error: container $container not found; start the replica (make site-up SITE=...) or set SITE" >&2; exit 2; }

if [ $# -gt 0 ]; then
  names="$*"
else
  names="$(docker exec "$container" sh -c "cd $contrib && grep -l 'digitalutsc/reusable_workflows' */.github/workflows/*.yml 2>/dev/null | cut -d/ -f1 | sort -u")"
fi
[ -n "$names" ] || { echo "error: no modules found in $container" >&2; exit 2; }

mkdir -p "$here/modules"
count=0
for name in $names; do
  dest="$here/modules/$name"
  rm -rf "$dest"
  docker cp "$container:$contrib/$name" "$dest" >/dev/null
  git -C "$dest" init -q -b main
  git -C "$dest" add -A
  git -C "$dest" -c user.name=local-github-actions -c user.email=local@localhost \
    commit -q -m "Deployed copy from $container" --no-verify
  count=$((count + 1))
done
echo "Copied $count modules from $container into modules/ (deployed releases, with the Lite site's composer patches applied)"
