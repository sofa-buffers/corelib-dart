---
name: release
description: Cut a release of corelib-dart (sofa_buffers_corelib) — version bump, CHANGELOG, release branch/PR, tag, GitHub release. Use when the user asks to "release", "cut a release", "tag a release", or runs /release. There was no documented process for this (no CLAUDE.md, no CONTRIBUTING.md); this skill was reverse-engineered from the v0.9.0/v0.10.0 release commits, the version-consistency.yml workflow, and CHANGELOG.md conventions — verify against those sources if the repo has moved on.
---

## Where this comes from

This repo has no CLAUDE.md/CONTRIBUTING.md describing a release process. This
skill was reconstructed by reading:

- `pubspec.yaml` — the **only** manifest carrying a version (single Dart
  package, no workspace/sub-packages).
- `.github/workflows/version-consistency.yml` — fires on `push: tags: ['v*']`
  and fails the run if `pubspec.yaml`'s `version:` doesn't match the pushed
  tag. **This is the closest thing to an authoritative spec of the release
  invariant**: tag `vX.Y.Z` ⇔ `pubspec.yaml` version `X.Y.Z`.
- The two real release commits, `5d95c6a` (`chore(release): 0.9.0`) and
  `53c0aa9` (`chore(release): 0.10.0`) — each touches only `pubspec.yaml` (+
  `CHANGELOG.md` when a real `## Unreleased` section existed to roll over),
  on a `release/vX.Y.Z` branch, merged via PR (`#26` for 0.10.0), then tagged
  and pushed, then a `gh release create` with hand-written notes.
- `CHANGELOG.md`'s own convention: unreleased work accumulates under a
  `## Unreleased` heading (added back by the first post-release commit that
  needs it — not part of the release step itself); releasing renames that
  heading to `## X.Y.Z - YYYY-MM-DD`.
- No `publish_to: none` in `pubspec.yaml`, but also **no workflow anywhere
  runs `dart pub publish`** — pub.dev publishing, if it happens at all, is
  manual and outside this skill's scope. Don't run it without being asked.

If `CLAUDE.md`/`CONTRIBUTING.md` exists by the time this runs, prefer it over
this skill and update this file to match.

## Preconditions

1. `git status` clean, on `main`, `git pull -p` up to date with
   `origin/main`. Refuse to branch from a dirty tree or a stale `main`.
2. `CHANGELOG.md`'s `## Unreleased` section (top of file) is non-empty. If
   it's missing or empty, stop and ask — nothing to release, or the
   changelog is out of date (check `git log <last tag>..HEAD --oneline` for
   commits that should have added an entry but didn't, and say so).
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

- Any `### Breaking` (or similar "breaking" wording) subheading under
  `## Unreleased` → bump **minor**, reset patch: `0.X.0` → `0.(X+1).0`.
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

## 4. Roll the CHANGELOG

In `CHANGELOG.md`, rename:

```
## Unreleased
```

to

```
## X.Y.Z - YYYY-MM-DD
```

using today's date (UTC, `YYYY-MM-DD`). Don't touch the body underneath, and
don't add a fresh `## Unreleased` heading — that's added by the next commit
that actually has something unreleased to say, same as after 0.10.0 (the
following commit `387cb4f` re-added it alongside its own entry, not the
release commit).

## 5. Commit

```
chore(release): X.Y.Z
```

Body: one paragraph summarizing what's shipping since the last tag, in the
style of the two real release commits — name the breaking changes
specifically (Crucible finding IDs, CORELIB_PLAN/MESSAGE_SPEC section
numbers, issue numbers) if this is a minor bump; a one-liner is enough for a
patch bump. Pull this from the `## Unreleased` entries you just rolled over,
don't invent new framing. End with the required attribution line for this
session (see system reminder) — these are `chore` commits like any other.

## 6. PR

```
git push -u origin release/vX.Y.Z
gh pr create --title "chore(release): X.Y.Z" --body "<same summary as the commit>"
```

Wait for CI to go green (`version-consistency.yml` does **not** run on this
PR — it only fires on the tag push later, so a manifest/tag mismatch won't
be caught until step 8; double-check the version by eye). Get it merged
(ask the user, or merge yourself if they said to proceed unattended) —
past releases merged via a normal merge commit (`gh pr merge --merge`), not
squash or rebase.

## 7. Tag

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

## 8. GitHub release

```
gh release create vX.Y.Z --title vX.Y.Z --notes "<notes>"
```

Notes: adapt (don't dump verbatim) the new `CHANGELOG.md` section — see
the `v0.10.0` release body for the target shape: 1-2 lead sentences, then a
bulleted list of breaking items with their Crucible/spec references, then
any cross-repo note (e.g. a lockstep companion generator/tool repo) if one
genuinely applies. Skip the cross-repo note if there's nothing to say.

## 9. Not part of this skill

- **pub.dev publish.** Nothing in CI does this today and it's a one-way
  door (pub.dev refuses to let a published version be replaced). Only run
  `dart pub publish` if the user explicitly asks for it, as a separate,
  confirmed step after the GitHub release exists.
- Updating sibling repos (e.g. a generator that tracks this library's
  version in lockstep, mentioned in past release notes) — out of scope
  here; flag it to the user if the changelog mentions such a dependency,
  but don't act on another repo.
