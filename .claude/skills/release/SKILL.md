---
name: release
description: Cut a release of corelib-dart (sofa_buffers_corelib) — version bump, release branch/PR, tag, GitHub release. Use when the user asks to "release", "cut a release", "tag a release", or runs /release. There was no documented process for this (no CLAUDE.md, no CONTRIBUTING.md); this skill was reverse-engineered from the v0.9.0/v0.10.0 release commits and the version-consistency.yml workflow — verify against those sources if the repo has moved on. CHANGELOG.md was removed 2026-09-24; version/breaking-change decisions and release notes are now derived from `git log` and this repo's conventional-commit `!` breaking-change marker (e.g. `refactor!:`, `feat!:`), not a changelog file.
---

## Where this comes from

This repo has no CLAUDE.md/CONTRIBUTING.md describing a release process. This
skill was reconstructed by reading:

- `pubspec.yaml` — the **only** manifest carrying a version (single Dart
  package, no workspace/sub-packages). Verified 2026-09-24 by grepping the
  whole tree for `version:`/`"version"` — the one other hit,
  `assets/test_vectors.json`'s `"version": 1`, is the shared test-vector
  schema version (tracks `corelib-c-cpp`'s vector format, not a release) and
  must **not** be touched by a release. Compare `corelib-c-cpp`'s
  `version-consistency.yaml`, which checks 4 files (`conanfile.py`,
  `library.json`, `library.properties`, `CMakeLists.txt`) because that repo
  publishes into 4 packaging ecosystems — Dart has one, so one file is the
  whole story here. **If a second version-carrying file ever appears**
  (e.g. a manifest for a tool that ships from this repo), extend
  `version-consistency.yml` with an additional check step for it, mirroring
  the C++ workflow's per-file pattern, and update this list.
- `.github/workflows/version-consistency.yml` — fires on `push: tags: ['v*']`
  and fails the run if `pubspec.yaml`'s `version:` doesn't match the pushed
  tag. **This is the closest thing to an authoritative spec of the release
  invariant**: tag `vX.Y.Z` ⇔ `pubspec.yaml` version `X.Y.Z`.
- The two real release commits, `5d95c6a` (`chore(release): 0.9.0`) and
  `53c0aa9` (`chore(release): 0.10.0`) — each touches only `pubspec.yaml` (+
  `CHANGELOG.md`, back when that file existed), on a `release/vX.Y.Z` branch,
  merged via PR (`#26` for 0.10.0), then tagged and pushed, then a
  `gh release create` with hand-written notes.
- This repo's conventional-commit convention: a commit type suffixed with
  `!` (e.g. `refactor!(decode): ...`, `feat!: ...`) marks a breaking change.
  Confirmed against real history (`c5da6ad`, `debbbfc`, `0258b9e`). Since
  `CHANGELOG.md` was removed (2026-09-24), this marker — not a changelog
  section — is what drives the minor-vs-patch decision in step 1.
- No `publish_to: none` in `pubspec.yaml`, but also **no workflow anywhere
  runs `dart pub publish`** — pub.dev publishing, if it happens at all, is
  manual and outside this skill's scope. Don't run it without being asked.

If `CLAUDE.md`/`CONTRIBUTING.md` exists by the time this runs, prefer it over
this skill and update this file to match.

## Preconditions

1. `git status` clean, on `main`, `git pull -p` up to date with
   `origin/main`. Refuse to branch from a dirty tree or a stale `main`.
2. `git log <last tag>..HEAD --oneline` is non-empty. If it's empty, stop
   and ask — there's nothing to release.
3. Local gate matches CI (`.github/workflows/ci.yml`) before cutting the
   branch:
   ```
   dart pub get
   dart format --output=none --set-exit-if-changed .
   dart analyze --fatal-infos
   dart test
   ```
   Fix or stop; don't release on a red tree.

## 1. Decide the version number

Find the latest tag: `git tag -l 'v*' | sort -V | tail -1`.

Pre-1.0 rule this repo follows (stated explicitly in both past release
commits): **a minor bump may break API or wire output.** So:

- Run `git log <last tag>..HEAD --oneline`. Any commit whose type is
  suffixed with `!` (e.g. `refactor!:`, `feat!:`) — this repo's
  conventional-commit breaking-change marker — → bump **minor**, reset
  patch: `0.X.0` → `0.(X+1).0`.
- Otherwise (fixes, perf, docs, test-only) → bump **patch**: `0.X.Y` →
  `0.X.(Y+1)`.
- If this would cross into `1.0.0` or the major otherwise needs to move,
  don't guess — ask the user to confirm first.

State the chosen version and why (which entries forced a minor bump, if any)
before proceeding.

## 2. Branch

```
git checkout -b release/vX.Y.Z main
```

## 3. Bump `pubspec.yaml`

Edit the top-level `version:` field only (it's the line matching
`^version:\s*\S+`, distinct from the `sdk: ^3.8.0` line under
`environment:` — see the comment in version-consistency.yml about why that
distinction matters). No other file in the repo carries a version string
(checked: README, workflows — none reference it).

## 4. Commit

```
chore(release): X.Y.Z
```

Body: one paragraph summarizing what's shipping since the last tag. Build it
from `git log <last tag>..HEAD --oneline` (or `--stat`/individual commit
bodies for more detail on any commit that needs it) — name the breaking
changes specifically (Crucible finding IDs, CORELIB_PLAN/MESSAGE_SPEC
section numbers, issue numbers) if this is a minor bump, pulling that detail
from the full commit message of each `!`-marked commit; a one-liner is
enough for a patch bump. Don't invent framing beyond what the commits
support. End with the required attribution line for this session (see
system reminder) — these are `chore` commits like any other.

## 5. PR

```
git push -u origin release/vX.Y.Z
gh pr create --title "chore(release): X.Y.Z" --body "<same summary as the commit>"
```

Wait for CI to go green (`version-consistency.yml` does **not** run on this
PR — it only fires on the tag push later, so a manifest/tag mismatch won't
be caught until step 6; double-check the version by eye). Confirm with the
user before merging — merging here is what sets up the tag/GitHub-release
steps that follow, and those are outward-facing and awkward to undo.

```
gh pr merge <n> --rebase --delete-branch
```

The two 2026 releases (`#26`) merged via a plain merge commit, but as of
the `0.11.0` release (`#100`) the repo only allows rebase merges —
`gh api repos/sofa-buffers/corelib-dart -q '{merge:.allow_merge_commit,
squash:.allow_squash_merge,rebase:.allow_rebase_merge}'` confirms which
methods are currently enabled; re-check it if `--rebase` ever starts
failing the same way `--merge` did here.

## 6. Tag

After the release PR is merged to `main`:

```
git checkout main && git pull -p
git tag vX.Y.Z
git push origin vX.Y.Z
```

**The tag must start with a lowercase `v`** — `v1.2.3`, never `1.2.3` or
`V1.2.3`. `version-consistency.yml`'s trigger is `tags: ['v*']`, which is a
case-sensitive glob: a tag not matching it exactly doesn't fire the workflow
at all, so a wrong-cased or unprefixed tag silently skips the one check that
verifies `pubspec.yaml` agrees with it.

This trips `version-consistency.yml` — check the run went green (confirms
`pubspec.yaml` matches the tag you just pushed; if it fails, the merge went
wrong and the tag needs deleting and redoing, not patching around).

## 7. GitHub release

```
gh release create vX.Y.Z --title vX.Y.Z --notes "<notes>"
```

Notes: build from `git log <previous tag>..vX.Y.Z --oneline` (same range
used for the commit body in step 4) — see the `v0.10.0` release body for the
target shape: 1-2 lead sentences, then a bulleted list of breaking items
(the `!`-marked commits) with their Crucible/spec references pulled from
those commits' full messages, then any cross-repo note (e.g. a lockstep
companion generator/tool repo) if one genuinely applies. Skip the cross-repo
note if there's nothing to say.

## 8. Not part of this skill

- **pub.dev publish.** Nothing in CI does this today and it's a one-way
  door (pub.dev refuses to let a published version be replaced). Only run
  `dart pub publish` if the user explicitly asks for it, as a separate,
  confirmed step after the GitHub release exists.
- Updating sibling repos (e.g. a generator that tracks this library's
  version in lockstep, mentioned in past release notes) — out of scope
  here; flag it to the user if the commits since the last tag mention such
  a dependency, but don't act on another repo.
