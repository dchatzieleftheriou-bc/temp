#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:?REPO is required}"
HEAD_REF="${HEAD_REF:-}"
RELEASE_LINE="${RELEASE_LINE:-}"

if [[ -n "${RELEASE_LINE}" ]]; then
  if [[ ! "${RELEASE_LINE}" =~ ^v[0-9]{4}(0[1-9]|1[0-2])\.[0-9]+\.[0-9]+$ ]]; then
    echo "Provided RELEASE_LINE '${RELEASE_LINE}' is invalid."
    exit 1
  fi
  release_line="${RELEASE_LINE}"
elif [[ -n "${HEAD_REF}" ]]; then
  matched_version=""
  if [[ "${HEAD_REF}" =~ ^release/(v?[0-9]{4}(0[1-9]|1[0-2])\.[0-9]+\.[0-9]+)$ ]]; then
    matched_version="${BASH_REMATCH[1]}"
  elif [[ "${HEAD_REF}" =~ ^merge/release/(v?[0-9]{4}(0[1-9]|1[0-2])\.[0-9]+\.[0-9]+)$ ]]; then
    matched_version="${BASH_REMATCH[1]}"
  else
    echo "PR head branch '${HEAD_REF}' is not a supported release branch; skipping."
    echo "Supported patterns: release/vYYYYMM.X.Y and merge/release/YYYYMM.X.Y"
    exit 0
  fi

  release_line="${matched_version#v}"
  release_line="v${release_line}"
else
  echo "Either HEAD_REF or RELEASE_LINE is required."
  exit 1
fi

echo "Publishing release line: ${release_line}"

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

draft_candidates_json="$(echo "${candidates_json}" | jq '[.[] | select(.draft == true)]')"
draft_candidate_count="$(echo "${draft_candidates_json}" | jq 'length')"
if [[ "${draft_candidate_count}" -eq 0 ]]; then
  echo "No draft release found for ${release_line}; nothing to publish."
  exit 1
fi

if [[ "${draft_candidate_count}" -gt 1 ]]; then
  echo "Multiple draft releases found for ${release_line}; refusing to guess."
  echo "${draft_candidates_json}" | jq -r '.[] | "- id=\(.id) name=\(.name) tag=\(.tag_name)"'
  exit 1
fi

release_id="$(echo "${draft_candidates_json}" | jq -r '.[0].id')"

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
