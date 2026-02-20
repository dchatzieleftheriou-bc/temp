#!/usr/bin/env bash
set -euo pipefail

TAG="${TAG:?TAG is required}"
REPO="${REPO:?REPO is required}"

if [[ ! "$TAG" =~ ^v[0-9]{4}(0[1-9]|1[0-2])\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]; then
  echo "Tag '$TAG' does not match release-candidate format, skipping."
  exit 0
fi

release_line="${TAG%-rc.*}"
echo "Release line: ${release_line}"

git fetch --tags --force

all_rc_tags="$(git tag -l "v*-rc.*" | sort -V)"
if [[ -z "${all_rc_tags}" ]]; then
  echo "No RC tags found; nothing to do."
  exit 1
fi

if ! echo "${all_rc_tags}" | grep -Fxq "${TAG}"; then
  echo "Current tag '${TAG}' was not found in repository tags."
  exit 1
fi

previous_tag="$(
  echo "${all_rc_tags}" | awk -v current="${TAG}" '
    {
      if ($0 == current) {
        print prev
        exit
      }
      prev = $0
    }
  '
)"

if [[ -n "${previous_tag}" ]]; then
  echo "Generating notes from previous tag: ${previous_tag}"
  payload="$(jq -n --arg tag "${TAG}" --arg prev "${previous_tag}" '{tag_name: $tag, previous_tag_name: $prev}')"
else
  echo "No previous RC tag found; generating notes from repository start."
  payload="$(jq -n --arg tag "${TAG}" '{tag_name: $tag}')"
fi

notes_body="$(gh api -X POST "repos/${REPO}/releases/generate-notes" --input - <<<"${payload}" | jq -r '.body')"

all_releases="$(gh api --paginate "repos/${REPO}/releases?per_page=100" | jq -s 'add')"

candidates_json="$(echo "${all_releases}" | jq --arg line "${release_line}" '
  [
    .[]
    | select(
        (.name == $line)
        or ((.tag_name // "") | test("^" + $line + "-rc\\.[0-9]+$"))
      )
  ]
')"

candidate_count="$(echo "${candidates_json}" | jq 'length')"
if [[ "${candidate_count}" -eq 0 ]]; then
  existing_release_id=""
else
  draft_candidate_count="$(echo "${candidates_json}" | jq '[.[] | select(.draft == true)] | length')"
  if [[ "${draft_candidate_count}" -gt 1 ]]; then
    echo "Multiple draft releases found for ${release_line}; refusing to guess."
    echo "${candidates_json}" | jq -r '.[] | select(.draft == true) | "- id=\(.id) name=\(.name) tag=\(.tag_name)"'
    exit 1
  fi

  if [[ "${draft_candidate_count}" -eq 1 ]]; then
    existing_release_id="$(echo "${candidates_json}" | jq -r '.[] | select(.draft == true) | .id')"
  elif [[ "${candidate_count}" -eq 1 ]]; then
    existing_release_id="$(echo "${candidates_json}" | jq -r '.[0].id')"
  else
    echo "Multiple non-draft releases matched ${release_line}; refusing to guess."
    echo "${candidates_json}" | jq -r '.[] | "- id=\(.id) draft=\(.draft) name=\(.name) tag=\(.tag_name)"'
    exit 1
  fi
fi

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
