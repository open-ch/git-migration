#!/usr/bin/env bash
set -o errexit
set -o pipefail
set -o nounset

red=$(tput setaf 1)
green=$(tput setaf 2)
bold=$(tput bold)
reset=$(tput sgr0)

MAX_SIZE_KB=${MAX_SIZE_KB:-1024}
MAX_SIZE_BYTES=$(( MAX_SIZE_KB * 1024 ))
SCRIPTS_REL_PATH=${0%/*}

main() {
  parse_arguments "$@"

  echo "Checking for files larger than ${bold}${MAX_SIZE_KB}kb${reset} in ${bold}${TARGET_REPO}${reset}"
  cd "$TARGET_REPO"
  check_large_files
}

parse_arguments() {
  if [ "$#" -ne 1 ]; then
      echo "Error: Invalid arguments, correct use:" >&2
      echo "$0 TARGET_REPO" >&2
      exit 1
  fi

  if [ ! -d "$1" ]; then
      echo "Error: TARGET_REPO argument must be a directory" >&2
      exit 1
  fi

  TARGET_REPO=$1
}

check_large_files() {
  # Originally from https://stackoverflow.com/a/42544963 by raphinesse
  LARGE_FILES=$(git rev-list --objects --all |
    git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' |
    awk -v limit="$MAX_SIZE_BYTES" '$1 ~ /blob/ && $3 >= limit {print $2, $3, $4}' |
    sort --numeric-sort --key=2 --reverse)

  if [[ -z "$LARGE_FILES" ]]; then
      echo "${green}${bold}No large files round, import to monorepo should be fine.${reset}"
  else
      echo "${red}${bold}One or more files are larger than the limit of ${MAX_SIZE_KB}KB ${reset}:"
      { echo blob-hash bytes file; echo "$LARGE_FILES"; } | column -t
      echo "The history needs to be cleaned before to importing into monorepo."
      echo "1. To find the corresponding commits use the git-find-blob.pm script:"
      echo "   ${bold}$SCRIPTS_REL_PATH/git-find-blob.pm $TARGET_REPO <BLOB_HASH>${reset}"
      echo "2. To remove the large blobs, use https://rtyley.github.io/bfg-repo-cleaner/"
      echo "   or git https://github.com/newren/git-filter-repo/"
      exit 1
  fi
}


main "$@"
