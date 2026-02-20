#!/usr/bin/env bash
set -euo pipefail

TAG="${TAG:?TAG is required}"
REPO="${REPO:?REPO is required}"

if [[ ! "$TAG" =~ ^v[0-9]{6}\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]; then
  echo "Tag '$TAG' does not match release-candidate format, skipping."
  exit 0
fi

release_line="${TAG%-rc.*}"
echo "Release line: ${release_line}"

git fetch --tags --force

series_tags="$(git tag -l "${release_line}-rc.*" | sort -V)"
if [[ -z "${series_tags}" ]]; then
  echo "No tags found for ${release_line}; nothing to do."
  exit 1
fi

first_series_tag="$(echo "${series_tags}" | head -n1)"
all_tags="$(git tag --sort=v:refname)"

baseline_prev_tag="$(
  echo "${all_tags}" | awk -v first="${first_series_tag}" '
    {
      if ($0 == first) {
        print prev
        exit
      }
      prev = $0
    }
  '
)"

if [[ -n "${baseline_prev_tag}" ]]; then
  payload="$(jq -n --arg tag "${TAG}" --arg prev "${baseline_prev_tag}" '{tag_name: $tag, previous_tag_name: $prev}')"
else
  payload="$(jq -n --arg tag "${TAG}" '{tag_name: $tag}')"
fi

notes_body="$(gh api -X POST "repos/${REPO}/releases/generate-notes" --input - <<<"${payload}" | jq -r '.body')"

existing_release_id="$(gh api "repos/${REPO}/releases?per_page=100" | jq -r --arg line "${release_line}" '
  map(select(.name == $line))
  | .[0].id // empty
')"

if [[ -z "${existing_release_id}" ]]; then
  echo "Creating draft release '${release_line}' on tag '${TAG}'."
  gh release create "${TAG}" \
    --repo "${REPO}" \
    --title "${release_line}" \
    --notes "${notes_body}" \
    --draft \
    --prerelease
else
  existing_is_draft="$(gh api "repos/${REPO}/releases/${existing_release_id}" | jq -r '.draft')"
  if [[ "${existing_is_draft}" != "true" ]]; then
    echo "Release '${release_line}' already exists and is published; refusing to modify it."
    exit 1
  fi

  echo "Updating existing release ${existing_release_id} to tag '${TAG}'."
  gh api -X PATCH "repos/${REPO}/releases/${existing_release_id}" \
    -f tag_name="${TAG}" \
    -f name="${release_line}" \
    -f body="${notes_body}" \
    -F draft=true \
    -F prerelease=true
fi
