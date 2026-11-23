#!/bin/sh
# The caller supplies the app Release MARKETING_VERSION and the tagged commit.
# Refs are injectable so offline tests use real Git ancestry without network access.
set -eu
if [ "$#" -ne 4 ]; then
  echo 'Usage: validate-tag.sh TAG PROJECT_VERSION COMMIT MAIN_REF' >&2
  exit 1
fi
tag=$1
project_version=$2
commit=$3
main_ref=$4
# Leading zeros are allowed by the required numeric grammar; comparison is literal.
# Reject newlines explicitly: grep otherwise validates each line independently.
case "$tag" in
  *'
'*) echo 'Release tag must be exactly numeric vMAJOR.MINOR.PATCH' >&2; exit 1 ;;
esac
if ! printf '%s\n' "$tag" | LC_ALL=C grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo 'Release tag must be exactly numeric vMAJOR.MINOR.PATCH' >&2
  exit 1
fi
if [ "${tag#v}" != "$project_version" ]; then
  echo "Release tag $tag does not match project MARKETING_VERSION $project_version" >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$commit" "$main_ref"; then
  echo "Tagged commit $commit is not reachable from $main_ref (or ref is unavailable)" >&2
  exit 1
fi
printf 'PASS release tag %s matches project %s and is reachable from %s\n' "$tag" "$project_version" "$main_ref"
