# local-github-actions

Run the GitHub Actions CI of the DSU Drupal modules on this machine, against a chosen branch of
[`digitalutsc/reusable_workflows`](https://github.com/digitalutsc/reusable_workflows) (default:
`omarhxk-patch-1`), without pushing anything to GitHub.

34 contrib modules in the Lite stack have a `.github/workflows/ci.yml` that calls
`digitalutsc/reusable_workflows/.github/workflows/islandora-module-ci.yml@main` (one, `assign_calc`,
calls `islandora-module-ci-d10only.yml`). This folder runs those workflows locally in two ways:

| | Pass A: `make test-act` | Pass B: `make test-direct` |
| --- | --- | --- |
| Runs | each module's own `ci.yml`, through [act](https://github.com/nektos/act) | the container the workflow's "PHPUnit tests" step starts, called directly |
| Workflow code | the branch's actual files, every step | only that one step |
| Answers | "what would GitHub report for this branch?" | "do the modules themselves pass, whatever runs before that step?" |
| Speed | one job at a time (the workflow uses fixed container and network names) | `JOBS` at a time (default 4) |

## Prerequisites

- Docker Desktop.
- act: `brew install act` (0.2.90 or newer; `--local-repository` is required).
- python3 with PyYAML (`python3 -m pip install pyyaml`).
- A running isle-lite replica to copy the modules from (default `stories`; any replica works, they share one image).

The first run pulls about 5 GB: `catthehacker/ubuntu:act-24.04` (act's runner, 2.3 GB),
`ghcr.io/islandora/ci` (four tags, ~0.6 GB each) and `drupalci/webdriver-chromedriver:production` (1.7 GB).
All have arm64 builds except chromedriver, which runs emulated; no module has tests that use it.

## Run it

```bash
cd dev-env/local-github-actions

make reusable      # clone reusable_workflows at omarhxk-patch-1 into ./reusable_workflows
make modules       # copy the 34 modules out of the stories replica into ./modules (one git commit each)
make test-act      # pass A: ~6 minutes on this Mac
make test-direct   # pass B: 136 runs, ~15-25 minutes with JOBS=6
make report        # headline of the newest report of each pass
```

The latest run's conclusions are in [`FINDINGS.md`](FINDINGS.md). Reports land in `results/` (`act-<time>.md` / `direct-<time>.md`, with the raw `.tsv` beside them); each row links
to its log under `logs/act/<branch>/<module>/` (one folder per `reusable_workflows` branch tested) or `logs/direct/`.

### Choosing the branch and the modules

Save your choices in `config.mk` (start from the example), or pass them on the command line, which wins over
`config.mk`:

```bash
cp config.mk.example config.mk     # then edit REUSABLE_REF, MODULES, SITE, DRUPAL, PHP, JOBS
make config                        # show what's in effect, and what reusable_workflows is checked out at
```

| Setting | Meaning | Default |
| --- | --- | --- |
| `REUSABLE_REF` | branch, tag or commit of `digitalutsc/reusable_workflows` to test | `omarhxk-patch-1` |
| `MODULES` | module directory names (under `web/modules/contrib`) to copy and test | empty = all 34 |
| `SITE` | replica to copy them from | `stories` |
| `DRUPAL`, `PHP`, `JOBS` | pass B pairings and parallelism | `10.6 11.3`, `8.3 8.4`, `4` |

After changing `REUSABLE_REF`, run `make reusable`; `test-act` refuses to run when the checkout doesn't match.
`MODULES` applies to `make modules`, `make test-act` and `make test-direct` alike; a module has to be copied
(`make modules`) before it can be tested. Pass A always runs the matrix the branch's workflow defines; `DRUPAL`/`PHP`
only shape pass B.

```bash
make reusable REUSABLE_REF=main && make test-act REUSABLE_REF=main   # one-off: test main
make modules test-direct MODULES="citation_select media_fits"         # one-off: two modules
```

### Common variations

```bash
make test-direct MODULES=citation_select DRUPAL=11.3 PHP=8.4 JOBS=1
make test-act MODULE_DIR=~/src/citation_select    # any directories instead of MODULES (each a git repo)
make modules SITE=memory                          # copy from another replica
make act-module MODULE_DIR=~/src/citation_select  # your own clone, all combinations in one act run*
make ci MODULE_DIR=~/src/citation_select DRUPAL=11.3 PHP=8.4   # your own clone, pass B style
make lint                                         # actionlint the branch's workflows
make inspect                                      # what the CI image does (entrypoint) and contains
```

\* `act-module` runs the whole matrix in one act invocation, so from the second job on it can trip over the first
job's leftover `ci-default` network. `make test-act MODULE_DIR=...` runs one combination at a time and cleans up in
between; use it for anything you want to trust.

To test a working copy of `reusable_workflows` instead of a fresh clone, point at it:
`make test-act REUSABLE_DIR=../reusable_workflows`.

## What the CI actually does

`ghcr.io/islandora/ci:<drupal>-php<php>` holds Drupal core only. Its entrypoint (`make inspect` prints it), with the
module mounted read-only at `web/modules/contrib/<module_name>`:

1. **phpcs** with `Drupal,DrupalPractice` on the module. Any error fails the job.
2. Starts a test server, then **`composer require`s every entry of the module's `composer.json` `require`**. A module's
   dependencies therefore have to be listed there; ones only named in `.info.yml` are not installed.
3. **phpunit** on the module directory (Unit, Kernel, Functional; FunctionalJavascript would use chromedriver).
   A module with no tests passes with 0 tests; the reports mark those `PASS (0 tests)`.

## Reading the results

- **Pass A failed step** is the workflow step that failed (`Constrain facets to matrix version`, `PHPUnit tests`, ...).
- **Pass B stage** sorts failures by the entrypoint stage: `phpcs: coding standard errors`,
  `composer: requirements not installable`, `phpunit: test failures/errors`, `phpunit: did not complete`, `other`.
- Open the linked log for the detail; `grep -n 'FOUND\|ERROR\|FAILURES\|Problem' <log>` gets to it fastest.

## Differences from GitHub

- **Module source.** `make modules` copies the release deployed in the Lite stack, not the repository's branch, and
  the Lite site's composer patches are applied to it (today only `ableplayer_extend` among these 34). Use your own
  clone (`act-module`, `ci`) to test a branch.
- **Architecture.** Runs arm64 natively here; GitHub's runners are amd64. Force amd64 with
  `ACT_ARCH=linux/amd64` (pass A) or `CI_PLATFORM=linux/amd64` (pass B); it is several times slower.
- **Fresh machine per job.** GitHub gives every job a new VM. Here pass A removes the workflow's fixed-name leftovers
  (`ci-default`, `drupal`, `chromedriver`) before each job; pass B gives every run its own `lga-<pid>-` names (with
  `drupal`/`chromedriver` kept as network aliases).
- **Composer cache.** Pass B shares a Composer cache volume (`lga-composer-cache`) between runs for speed; GitHub
  downloads every time. `COMPOSER_CACHE_VOLUME=` turns it off.
- **act.** Ignores `permissions:` and `concurrency:`, uses `catthehacker/ubuntu:act-24.04` as the runner, and maps
  `digitalutsc/reusable_workflows@main` to `REUSABLE_DIR` with `--local-repository`. How GitHub itself resolves
  `@main` and nested reusable workflows can only be checked on GitHub.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `network with name ci-default already exists` / `container name "/drupal" is already in use` | A job was interrupted: `make clean` (or `docker rm -f drupal chromedriver; docker network rm ci-default`). |
| `container isle-lite-drupal-stories-1 not found` | Start a replica (`make site-up SITE=stories` in `isle-lite-dsu/`) or `make modules SITE=<running site>`. |
| `this act has no --local-repository` | `brew upgrade act`. |
| `python3 needs PyYAML` | `python3 -m pip install pyyaml` (into the python3 on your PATH). |
| act prints `not located inside a git repository` | The module dir isn't a git repo; `make modules` creates one per module. Harmless otherwise. |

## Files

| File | Role |
| --- | --- |
| `Makefile`, `config.mk.example` | entry points (`make help`); optional `config.mk` settings |
| `fetch-modules.sh` | `make modules` |
| `run-act-all.sh`, `lib/matrix.py` | pass A; `matrix.py` expands the called workflow's matrix (literal lists or `fromJSON(inputs.X)`, product/exclude/include, through wrapper workflows) into act `--matrix` filters |
| `run-direct-all.sh`, `run-module-ci.sh` | pass B; `run-module-ci.sh` is the single-module runner (`make ci`) |
| `run-act.sh` | act on `reusable_workflows`' self-test or one module (`act-selftest`, `act-module`) |
| `inspect-image.sh` | `make inspect` |
| `lib/report.py` | TSV → Markdown report |
| `reusable_workflows/`, `modules/`, `logs/`, `results/` | generated; `make clean` removes all but `reusable_workflows/` |
