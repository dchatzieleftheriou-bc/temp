#!/usr/bin/env bash
set -euo pipefail

HEAD_REF="${HEAD_REF:?HEAD_REF is required}"
REPO="${REPO:?REPO is required}"

matched_version=""
if [[ "${HEAD_REF}" =~ ^release/(v?[0-9]{6}\.[0-9]+\.[0-9]+)$ ]]; then
  matched_version="${BASH_REMATCH[1]}"
elif [[ "${HEAD_REF}" =~ ^merge/release/(v?[0-9]{6}\.[0-9]+\.[0-9]+)$ ]]; then
  matched_version="${BASH_REMATCH[1]}"
else
  echo "PR head branch '${HEAD_REF}' is not a supported release branch; skipping."
  echo "Supported patterns: release/vYYYYMM.X.Y and merge/release/YYYYMM.X.Y"
  exit 0
fi

release_line="${matched_version#v}"
release_line="v${release_line}"
echo "Publishing release line: ${release_line}"

release_id="$(gh api "repos/${REPO}/releases?per_page=100" | jq -r --arg line "${release_line}" '
  map(select(.name == $line))
  | .[0].id // empty
')"

if [[ -z "${release_id}" ]]; then
  echo "No release found for ${release_line}; nothing to publish."
  exit 1
fi

is_draft="$(gh api "repos/${REPO}/releases/${release_id}" | jq -r '.draft')"
if [[ "${is_draft}" != "true" ]]; then
  echo "Release ${release_id} is already published."
  exit 0
fi

gh api -X PATCH "repos/${REPO}/releases/${release_id}" \
  -F draft=false \
  -F prerelease=false

echo "Release ${release_line} is now published."
