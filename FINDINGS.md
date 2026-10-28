# Findings: module CI against reusable_workflows `omarhxk-patch-1` (2026-10-28)

Run on this Mac (arm64, native images) with the tooling in this folder. Module code: the releases deployed in the
isle-lite `stories` replica (34 modules whose `ci.yml` calls `digitalutsc/reusable_workflows`). CI images
`ghcr.io/islandora/ci:{10.6,11.3}-php{8.3,8.4}` as pulled on 2026-10-28 (Drupal core 11.3.16 in the 11.3 tags).
Full tables: `results/act-*.md` (pass A) and `results/direct-*.md` (pass B); rerun with `make test`.

## Pass A: what GitHub would report for the branch (act, the branch's workflow files)

134 jobs, **5 passed, 129 failed**.

- **128 jobs (32 modules) fail at "Constrain facets to matrix version"**, before any test runs. The step ends with
  `grep -n "drupal/facets" composer.json`, which exits 1 for every module that doesn't depend on Facets.
- `facets_year_range`: 4/4 pass (Facets 2.0.10 on Drupal 10.6, 3.0.7 on 11.3; `OK (1 test, 29 assertions)`).
- `assign_calc` (calls `islandora-module-ci-d10only.yml`, which has no facets step): PHP 8.4 passes; PHP 8.3 fails in
  Composer (see below).

## Pass B: the modules themselves (the workflow's PHPUnit container, run directly)

136 runs, **95 passed (28 of them ran 0 tests), 41 failed**; 23 of 34 modules green on every pairing.

| Cause | Modules (runs) | Fix belongs in |
| --- | --- | --- |
| `composer.json` lists `drupal/core` in `require`. The image `composer require`s it, which re-checks the image's locked core; that core (11.3.16 / 10.6.x) has open advisories (SA-CORE-2026-013…016), so Composer's security blocking refuses it. | archive_list_contents, islandora_iiif_hocr_extend, islandora_site_name, language_switcher_popup, leafletjs, media_thumbnails_jp2, media_thumbnails_tiff, termwithuri_condition (32) | the modules: drop `drupal/core` from `require` (the core range belongs in `.info.yml`); goes away by itself when the CI image ships a patched core |
| phpcs `Drupal,DrupalPractice`: 8 errors in `islandora_group.module` (tabs, spacing, line length) | islandora_group (4) | the module (`phpcbf` fixes the `[x]` ones) |
| Install config `field.field.node.assignment.body` needs `field.storage.node.body`, which Drupal 11's node module no longer provides | assign_calc on 11.3 (2) | the module: ship the field storage in its config. The d10only workflow it uses hides this |
| `drupal/admin_toolbar ^3.5` not installable on the 10.6-php8.3 image (newer releases need `drupal/toolbar`, Drupal ^11.3) | assign_calc 10.6/PHP 8.3 (1) | the module: `admin_toolbar`, `devel`, `devel_php` are runtime `require`s of a module that doesn't need them |
| Unpinned, Composer picks Facets 3.0.7, whose test trait uses a Drupal 11-only class (`EntityTestHelper`) | facets_year_range on 10.6 (2) | the module: `"drupal/facets": "^2"` (verified: passes on 10.6 in pass A and on 11.3 here). This is what the branch's facets step was working around |

**0 tests** (green, nothing tested): advanced_search_default_sort_override, group_concat, islandora_breadcrumbs,
islandora_iiif, relation_extend, rest_translation_util, xmlsitemap_extend (and the composer-failing
archive_list_contents, islandora_iiif_hocr_extend, islandora_site_name, language_switcher_popup,
media_thumbnails_jp2/tiff, termwithuri_condition would be too once installable). `ableplayer_extend`'s one test is
at `src/Functional/LoadTest.php` instead of `tests/src/Functional/`; PHPUnit finds it only because it scans the whole
module directory.

## What this means for the branch

- Don't merge the facets step as is: it turns 32 modules red. Its goal is right for `facets_year_range`, but the fix
  belongs in that module's `composer.json` (`^2`).
- With the step removed, the branch's workflow is a no-op change for everything except `facets_year_range`; the
  remaining failures are in the modules (table above), not in the workflow.

---

# Same tests against reusable_workflows `claude-reswork` (`a262e7a`, 2026-10-28)

`claude-reswork` is identical to the reviewed local rework (pinned checkout, `permissions: contents: read`,
concurrency, timeout, `drupal_versions`/`php_versions` inputs, `env:` for the module name, d10only as a wrapper, no
facets step). Pass A: `results/act-20261028-143654.md`, logs under `logs/act/claude-reswork/`. Pass B doesn't depend on
the branch (it runs the test container directly), so its results above apply unchanged.

**Pass A: 134 jobs, 94 passed (28 of them ran 0 tests), 40 failed.** Every failure is in the "PHPUnit tests" step,
i.e. inside the CI image; none is in the workflow itself.

| | `omarhxk-patch-1` | `claude-reswork` |
| --- | --- | --- |
| Jobs passed | 5 / 134 | 94 / 134 |
| Modules green on every job | 1 | 22 |
| Failures caused by the workflow | 128 (facets step) | 0 |

- **133 of 134 jobs match pass B exactly**, so with this branch the CI reports the modules' own state: the 11 failing
  modules and causes in the pass B table (8 × `drupal/core` in `composer.json`, islandora_group phpcs, assign_calc,
  facets_year_range on 10.6).
- **The one mismatch was a flake:** `recogito_integration` Drupal 11.3 / PHP 8.3 failed once with
  `find: web/sites/default/files/php/twig/...: No such file or directory`. The image's entrypoint runs `find web ...`
  while the test server it just started writes and deletes Twig cache files; `set -e` turns the vanished file into a
  failure. The same job passed 3/3 reruns. This is a race in `ghcr.io/islandora/ci`'s entrypoint and can happen on
  GitHub too.
- **`facets_year_range` goes from 4/4 to 2/4:** without the branch's facets step its Drupal 10.6 jobs pick Facets 3 and
  fail. Expected; the fix is `"drupal/facets": "^2"` in the module (verified in pass B).
- **The d10only wrapper works:** `assign_calc`'s CI calls it, it calls `islandora-module-ci.yml@main` (mapped to this
  branch) with `drupal_versions: '["10.6"]'`, and runs the same two jobs with the same results as before.

Not verifiable with act: the pinned `actions/checkout` commit (act substitutes its own local checkout for the repository
under test), `permissions:`, `concurrency:`, and GitHub's own resolution of `@main` and the nested call. Check those
with one real run on GitHub, e.g. a module PR pointing at `@claude-reswork`.
