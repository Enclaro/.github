#!/usr/bin/env bash
set -euo pipefail

mkdir -p backup/github work
repos_file="$(mktemp)"

if [[ -n "$TRVNY_TOKEN" && -n "$ORG_TOKEN" ]]; then
  auth_mode="gptomek-app"
  GH_TOKEN="$TRVNY_TOKEN" gh api --paginate installation/repositories \
    --jq '.repositories[].full_name' >> "$repos_file"
  GH_TOKEN="$ORG_TOKEN" gh api --paginate installation/repositories \
    --jq '.repositories[].full_name' >> "$repos_file"
else
  auth_mode="public-fallback"
  GH_TOKEN="$PUBLIC_TOKEN" gh api --paginate \
    'users/trvny/repos?type=owner&per_page=100' \
    --jq '.[] | select(.visibility == "public") | .full_name' >> "$repos_file"
  GH_TOKEN="$PUBLIC_TOKEN" gh api --paginate \
    'orgs/travnie/repos?type=public&per_page=100' \
    --jq '.[].full_name' >> "$repos_file"
fi
sort -u -o "$repos_file" "$repos_file"
if [[ ! -s "$repos_file" ]]; then
  echo "::error::Repository discovery returned no repositories."
  exit 1
fi

while IFS= read -r repo; do
  [[ -n "$repo" ]] || continue
  owner="${repo%%/*}"
  name="${repo#*/}"

  case "$owner" in
    trvny) token="$TRVNY_TOKEN" ;;
    travnie) token="$ORG_TOKEN" ;;
    *) continue ;;
  esac

  mirror="work/$owner/$name.git"
  archive="backup/github/$owner/$name.git.tar.gz"
  metadata_dir="work/github-metadata/$owner/$name"
  metadata_archive="backup/github/metadata/$owner/$name.github-metadata.tar.gz"
  mkdir -p \
    "work/$owner" \
    "backup/github/$owner" \
    "work/github-metadata/$owner" \
    "backup/github/metadata/$owner"

  if [[ -n "$token" ]]; then
    auth="$(printf 'x-access-token:%s' "$token" | base64 -w0)"
    git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" \
      clone --mirror "https://github.com/$repo.git" "$mirror"
    git -C "$mirror" \
      -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" \
      lfs fetch --all
  else
    git clone --mirror "https://github.com/$repo.git" "$mirror"
    git -C "$mirror" lfs fetch --all
  fi

  git -C "$mirror" fsck --full

  api_token="$token"
  if [[ -z "$api_token" ]]; then
    api_token="$PUBLIC_TOKEN"
  fi
  backup_filter_paths=""
  if [[ "$repo" == "$FILTERED_REPOSITORY" ]]; then
    backup_filter_paths="$FILTERED_PATHS"
  fi
  GH_TOKEN="$api_token" GIT_AUTH_TOKEN="$token" \
    BACKUP_GIT_FILTER_PATHS="$backup_filter_paths" node \
    "$GITHUB_WORKSPACE/.github/scripts/github-backup-metadata.cjs" \
    "$repo" "$mirror" "$metadata_dir"

  if [[ "$repo" == "$FILTERED_REPOSITORY" ]]; then
    git -C "$mirror" for-each-ref --format='%(refname) %(objectname)' \
      | sort > "$metadata_dir/git-source-refs.txt"
    filter_args=()
    for filter_path in $FILTERED_PATHS; do
      filter_args+=(--path "$filter_path")
    done
    git -C "$mirror" filter-repo "${filter_args[@]}" --invert-paths --force

    lfs_oids="$(mktemp)"
    git -C "$mirror" lfs ls-files --all --long \
      | awk '{print $1}' | sort -u > "$lfs_oids"
    lfs_objects="$mirror/lfs/objects"
    if [[ -d "$lfs_objects" ]]; then
      while IFS= read -r -d '' lfs_object; do
        oid="$(basename "$lfs_object")"
        if ! grep -Fxq "$oid" "$lfs_oids"; then
          rm -f "$lfs_object"
        fi
      done < <(find "$lfs_objects" -type f -print0)
    fi
    while IFS= read -r oid; do
      [[ -n "$oid" ]] || continue
      object="$lfs_objects/${oid:0:2}/${oid:2:2}/$oid"
      if [[ ! -f "$object" ]]; then
        echo "::error::Missing retained LFS object $oid for $repo."
        exit 1
      fi
    done < "$lfs_oids"

    test -s "$mirror/filter-repo/commit-map"
    cp "$mirror/filter-repo/commit-map" \
      "$metadata_dir/git-rewrite-commit-map.txt"
    git -C "$mirror" for-each-ref --format='%(refname) %(objectname)' \
      | sort > "$metadata_dir/git-backup-refs.txt"

    source_ref_names="$(mktemp)"
    backup_ref_names="$(mktemp)"
    awk '{print $1}' "$metadata_dir/git-source-refs.txt" > "$source_ref_names"
    awk '{print $1}' "$metadata_dir/git-backup-refs.txt" > "$backup_ref_names"
    diff -u "$source_ref_names" "$backup_ref_names"

    {
      printf 'strategy=full-history-filtered-paths\n'
      printf 'repository=%s\n' "$repo"
      printf 'git_contributors_scope=unfiltered-source-history\n'
      printf 'commit_map=git-rewrite-commit-map.txt\n'
      printf 'excluded_paths:\n'
      for filter_path in $FILTERED_PATHS; do
        printf '  - %s\n' "$filter_path"
      done
    } > "$metadata_dir/GIT_FILTER.txt"

    restore_test="$GITHUB_WORKSPACE/work/restore-test/$owner/$name.git"
    mkdir -p "$(dirname "$restore_test")"
    git init --bare "$restore_test"
    git -C "$mirror" push --mirror "$restore_test"
    git -C "$restore_test" fsck --full
    diff -u \
      <(git -C "$mirror" for-each-ref --format='%(refname) %(objectname)' | sort) \
      <(git -C "$restore_test" for-each-ref --format='%(refname) %(objectname)' | sort)
    rm -rf "$restore_test"
  fi

  git -C "$mirror" fsck --full
  tar -C "work/$owner" -czf "$archive" "$name.git"
  tar -C "work/github-metadata/$owner" \
    -czf "$metadata_archive" "$name"
done < "$repos_file"

(
  cd backup/github
  find . -type f -name '*.tar.gz' -print0 \
    | sort -z \
    | xargs -0 sha256sum
) > backup/github/SHA256SUMS

archives_file="$(mktemp)"
find backup/github -type f -name '*.tar.gz' -printf '%P\n' \
  | sort -u > "$archives_file"

{
  printf 'generated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'repository_count=%s\n' "$(wc -l < "$repos_file" | tr -d ' ')"
  printf 'archive_count=%s\n' "$(wc -l < "$archives_file" | tr -d ' ')"
  printf 'auth_mode=%s\n' "$auth_mode"
  printf 'metadata_export_schema_current=3\n'
  printf 'metadata_export_schema_source=per-archive:EXPORT.json\n'
  if [[ -n "$FILTERED_REPOSITORY" ]]; then
    printf 'filtered_git=%s:paths-%s\n' "$FILTERED_REPOSITORY" "${FILTERED_PATHS// /,}"
  fi
  printf 'repositories:\n'
  sed 's/^/  - /' "$repos_file"
  printf 'archives:\n'
  sed 's/^/  - /' "$archives_file"
} > backup/github/MANIFEST.txt
