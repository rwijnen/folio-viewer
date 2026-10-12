#!/usr/bin/env bash
#
# Fails a pull request that changes the app without making it a release.
#
#   .github/scripts/check-version-bump.sh <base-ref>
#
# A release follows the version in the bundle: merging to main publishes only when
# CFBundleShortVersionString names a version that has no tag yet. Feature and fix PRs
# kept landing without the bump, and each one merged quietly into a release that never
# came. So a PR that touches Sources/ or Resources/ must raise the version above the
# base branch's, raise the build number, and give the new version a CHANGELOG heading.
# Anything else — docs, tests, CI — needs none of that, so a README fix still does not
# become a version.
set -euo pipefail

base="${1:?usage: check-version-bump.sh <base-ref>}"
plist=Resources/Info.plist

changed=$(git diff --name-only "$base"...HEAD)
app_changes=$(printf '%s\n' "$changed" | grep -E '^(Sources|Resources)/' || true)
if [[ -z "$app_changes" ]]; then
  echo "No change to Sources/ or Resources/ — no release needed."
  exit 0
fi
echo "App files changed:"
printf '  %s\n' $app_changes

read_key() { plutil -extract "$1" raw -o - - ; }
base_version=$(git show "$base:$plist" | read_key CFBundleShortVersionString)
base_build=$(git show "$base:$plist" | read_key CFBundleVersion)
head_version=$(read_key CFBundleShortVersionString < "$plist")
head_build=$(read_key CFBundleVersion < "$plist")
echo "Version: $base_version ($base_build) on the base → $head_version ($head_build) here"

problems=0
highest=$(printf '%s\n%s\n' "$base_version" "$head_version" | sort -V | tail -1)
if [[ "$head_version" == "$base_version" || "$highest" != "$head_version" ]]; then
  echo "::error file=$plist::This PR changes the app, so CFBundleShortVersionString must go up from $base_version (it is $head_version). Fix → patch, feature → minor, breaking → major; otherwise merging publishes nothing."
  problems=1
fi
if ! [[ "$head_build" =~ ^[0-9]+$ && "$base_build" =~ ^[0-9]+$ ]] || (( head_build <= base_build )); then
  echo "::error file=$plist::CFBundleVersion must go up from $base_build."
  problems=1
fi
if git rev-parse --verify --quiet "refs/tags/v$head_version" > /dev/null; then
  echo "::error file=$plist::v$head_version is already released. Pick the next version."
  problems=1
fi
if ! grep -q "^## \[$head_version\]" CHANGELOG.md; then
  echo "::error file=CHANGELOG.md::CHANGELOG.md has no '## [$head_version] — YYYY-MM-DD' heading; the Release workflow refuses to publish without it."
  problems=1
fi

if (( problems )); then
  echo "See 'Releasing' in CLAUDE.md."
  exit 1
fi
echo "Merging this publishes Folio $head_version."
