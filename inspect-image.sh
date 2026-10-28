#!/usr/bin/env bash
# Show what a ghcr.io/islandora/ci image does with a mounted module: its
# entrypoint and command (and the scripts they name), and the Drupal packages
# already installed in it. Nothing in islandora-module-ci.yml installs a
# module's dependencies, so this is the list a module can depend on.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: inspect-image.sh [-d DRUPAL] [-p PHP] [-q PACKAGE]

  -d DRUPAL   Drupal version of the tag (default: 11.3)
  -p PHP      PHP version of the tag (default: 8.4)
  -q PACKAGE  only report this Composer package (e.g. drupal/facets)
  -h          this help

Environment: CI_IMAGE (default: ghcr.io/islandora/ci), CI_PLATFORM (default: linux/amd64)
EOF
}

drupal="11.3"
php="8.4"
package=""
while getopts "d:p:q:h" opt; do
  case "$opt" in
    d) drupal="$OPTARG" ;;
    p) php="$OPTARG" ;;
    q) package="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

image="${CI_IMAGE:-ghcr.io/islandora/ci}:$drupal-php$php"
platform="${CI_PLATFORM:-linux/amd64}"

in_image() {
  docker run --rm --platform "$platform" --entrypoint sh "$image" -c "$1"
}

if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "Pulling $image ($platform)"
  docker pull --platform "$platform" "$image"
fi

# Lists the installed packages from Composer's own record, so it works whether
# or not the composer binary is on PATH in the image. PHP code: no expansion.
# shellcheck disable=SC2016
packages_php='
$f = getenv("ROOT") . "/vendor/composer/installed.json";
if (!is_file($f)) { fwrite(STDERR, "no $f\n"); exit(1); }
$j = json_decode(file_get_contents($f), true);
foreach ($j["packages"] ?? $j as $p) {
  $want = getenv("PKG");
  if ($want !== "" && $p["name"] !== $want) continue;
  if ($want === "" && !preg_match("#^(drupal|islandora)/#", $p["name"])) continue;
  printf("%-50s %s\n", $p["name"], $p["version"]);
}'

if [ -n "$package" ]; then
  in_image "ROOT=/var/www/drupal PKG='$package' php -r '$packages_php'"
  exit
fi

echo "== $image"
docker image inspect "$image" --format \
  'Entrypoint: {{json .Config.Entrypoint}}
Cmd:        {{json .Config.Cmd}}
WorkingDir: {{.Config.WorkingDir}}
Env:        {{json .Config.Env}}'

# Print every absolute path named by the entrypoint or command that is a
# script in the image.
paths="$(docker image inspect "$image" --format '{{range .Config.Entrypoint}}{{println .}}{{end}}{{range .Config.Cmd}}{{println .}}{{end}}' | grep '^/' || true)"
for p in $paths; do
  echo
  echo "== $p"
  in_image "if [ -f '$p' ] && grep -Iq . '$p'; then cat '$p'; else echo '(not a text file)'; fi"
done

echo
echo "== drupal/* and islandora/* packages installed in /var/www/drupal"
in_image "ROOT=/var/www/drupal PKG= php -r '$packages_php'"
