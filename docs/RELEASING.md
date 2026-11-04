# Releasing ASH

This document is the release runbook for ASH. It covers the version domain,
the release commit, the tag-triggered workflow, release candidates, hotfixes,
rollback, and the repository settings that must exist before the first tag.

The process is intentionally fail-closed. A release is created only when the
tag, the code version, the changelog, the branch, and the CI result all agree.

## Version domain

ASH uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- stable: `MAJOR.MINOR.PATCH`, for example `2.2.0`;
- release candidate: `MAJOR.MINOR.PATCH-rc.N`, for example `2.3.0-rc.1`.

Git tags add a `v` prefix: `v2.2.0`, `v2.3.0-rc.1`. No other tag form is
accepted. Leading zeroes, `v2.2`, `2.2.0`, and `v2.2.0-rc.0` are rejected.

`ASH_VERSION` in `src/agent/ash-agent.sh` is canonical. These values must match
it exactly:

- `VERSION` in `scripts/install.sh`;
- the version literals in `README.md` and `ash_documentation.md`;
- the tag version (without the `v` prefix).

`scripts/validate-release.sh` enforces all of them. It runs on every pull
request and again in the release workflow.

## Changelog

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
It always has one `## [Unreleased]` section. A release adds a section in this
exact form:

```markdown
## [2.3.0] - 2026-11-04
```

The date is the UTC date of the release. The section must contain at least one
non-empty line that is not a `###` heading. Duplicate version sections and
invalid dates fail validation.

Release notes are extracted from that section. If the section is missing or
empty, the release fails; notes are never generated from commit messages.

## Release checklist

1. Confirm `main` is green. The release workflow requires a successful
   `ci-success` job for the exact tag commit.
2. Create a release pull request that does all of the following:
   - bump `ASH_VERSION` in `src/agent/ash-agent.sh`;
   - bump `VERSION` in `scripts/install.sh` to the same value;
   - update the version literals in `README.md` and `ash_documentation.md`;
   - move the relevant `Unreleased` entries under
     `## [X.Y.Z] - YYYY-MM-DD` and leave an empty `Unreleased` section.
3. Run the validator locally:

   ```bash
   ./scripts/validate-release.sh
   ```

4. Merge the release pull request after CI passes.
5. Tag the merged commit on `main` and push the tag:

   ```bash
   git switch main
   git pull --ff-only
   git tag -a v2.3.0 -m "ASH v2.3.0"
   git push origin v2.3.0
   ```

   Never use `git tag -f`, `git push --force`, or a tag on a commit that is not
   on `main`.
6. Watch the `ASH Release` workflow. It validates the tag, builds
   `ash-monitor-2.3.0.tar.gz`, writes `SHA256SUMS` and `release-notes.md`,
   and creates the GitHub Release.
7. Verify the published release:

   ```bash
   gh release view v2.3.0
   gh release download v2.3.0 --dir /tmp/ash-release
   cd /tmp/ash-release
   sha256sum -c SHA256SUMS
   ```

`backup-before-ash-1.5` is a historical backup tag, not a release. Do not use
it as a release baseline or present it as one.

## What the release workflow validates

The workflow is triggered by a `v*` tag (or by an explicitly validated manual
recovery run) and fails unless:

1. the tag matches the version domain;
2. the tag version equals `ASH_VERSION`;
3. `scripts/install.sh` agrees with `ASH_VERSION`;
4. `README.md` and `ash_documentation.md` agree with `ASH_VERSION`;
5. `CHANGELOG.md` has exactly one `Unreleased` section and a non-empty section
   for the tag version;
6. the tag commit is an ancestor of `origin/main`;
7. a successful `ASH CI` run, including the `ci-success` job, exists for the
   exact tag commit;
8. no GitHub Release already exists for the tag.

The release job uses `contents: write` and `actions: read`; the workflow default
remains `contents: read`. It uses first-party `gh release create` rather than a
third-party release Action.

## Release candidates

A release candidate is a normal release with a pre-release suffix:

1. set `ASH_VERSION` and `VERSION` to `2.3.0-rc.1`;
2. add `## [2.3.0-rc.1] - YYYY-MM-DD` to `CHANGELOG.md`;
3. merge, tag `v2.3.0-rc.1`, and push the tag;
4. the workflow creates a GitHub pre-release.

Do not retag a release candidate. To promote it, bump the version to `2.3.0`,
add the stable changelog section, merge, and tag `v2.3.0`.

## Hotfixes

A hotfix starts from the released tag, not from an arbitrary `main` commit:

```bash
git switch -c hotfix/2.2.1 v2.2.0
```

Apply the smallest fix, bump `ASH_VERSION` and `VERSION` to `2.2.1`, add the
`## [2.2.1] - YYYY-MM-DD` section, and open a pull request to `main`. Once it
is merged and `ci-success` passes, tag `v2.2.1` from `main`. If `main` contains
unrelated changes, cherry-pick the fix onto a release branch and follow the
same release checklist; do not move the old tag.

## Rollback and yanking

Published tags are immutable. Never move, delete, or force-push a tag that has
been published, and never re-upload different bytes under the same version.

- **Bad code or bad artifact:** publish the next patch release with the fix.
  Mark the affected release as superseded in its notes if needed.
- **Wrong release notes or metadata:** edit the release object, not the tag:

  ```bash
  gh release edit v2.3.0 --notes-file path/to/corrected-notes.md
  ```

- **Release should not be offered as stable:** mark it as a pre-release:

  ```bash
  gh release edit v2.3.0 --prerelease
  ```

  This changes the GitHub release metadata only; the tag and assets remain.
- **Asset upload failed after the release was created:** re-upload explicitly,
  after verifying the checksum locally:

  ```bash
  gh release upload v2.3.0 dist/ash-monitor-2.3.0.tar.gz dist/SHA256SUMS --clobber
  ```

  `--clobber` is a manual recovery step. The workflow itself refuses to
  overwrite an existing release.

## Manual recovery run

If the tag push did not start the workflow, use **Actions → ASH Release → Run
workflow** and provide the tag. The manual path performs the same validation as
the tag push; it does not bypass the tag/version, changelog, `main`, CI, or
duplicate-release checks. If the release already exists, the run fails by
design.

## Required repository settings

This repository change adds the workflow and validator but does not change
repository settings. Before the first real tag, an administrator must:

- create a `release` environment with required reviewers;
- allow GitHub Actions to obtain a write token (or the job-level
  `contents: write` is downgraded and release creation fails);
- protect `main` with the required `ci-success` check and review;
- add a `v*` tag ruleset that restricts create, update, and delete to release
  maintainers;
- add `environment: release` to the release job once the environment exists, so
  the approval is enforced by the workflow rather than only documented.

These settings are tracked as a follow-up to the release-process work. Until
they exist, the workflow still validates the tag, branch, CI result, and
changelog, but it cannot enforce a human approval step.

## Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| `tag/version mismatch` | Tag does not equal `ASH_VERSION` | Fix the release commit, merge, and create a new tag; do not move the old tag |
| `version drift` | `scripts/install.sh` differs from `ASH_VERSION` | Update both in the release pull request |
| `no non-empty section` | Changelog section is missing or empty | Add the `## [X.Y.Z] - YYYY-MM-DD` section and entries |
| `not an ancestor of origin/main` | Tag was created on a branch or unmerged commit | Merge the commit to `main` first, then tag the merged commit |
| `no successful ASH CI run` | CI is still running or failed for that SHA | Wait for or fix CI, then re-run the release workflow |
| `release already exists` | The tag was already released | Do not overwrite; publish a new patch or use the explicit asset re-upload step |
| `notes directory does not exist` | `--notes-file` points into a missing directory | Create the directory or use the workflow's `dist/` output |

## Local commands

```bash
# Validate the current tree (pull-request mode).
./scripts/validate-release.sh

# Validate a tag and write its release notes.
./scripts/validate-release.sh --tag v2.3.0 --notes-file /tmp/release-notes.md

# Build the archive, checksums, and notes without creating a release.
./scripts/build-release.sh --version 2.3.0 --output-dir dist

# Verify the archive checksum.
cd dist && sha256sum -c SHA256SUMS
```
