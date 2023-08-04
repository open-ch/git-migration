#!/usr/bin/env bash
set -o errexit
set -o pipefail
set -o nounset
#
# Migration part 2: merging/committing the changes to the trunk branch

TARGET_REPO_PATH=${TARGET_REPO_PATH:-}
TARGET_TRUNK_BRANCH=${TARGET_TRUNK_BRANCH:-master}
TARGET_REMOTE=${TARGET_REMOTE:-origin}
DRY_RUN=${DRY_RUN:-0}

main() {
    if [ "$#" -ne 1 ]; then
        echo "Error: Invalid arguments, correct use:" >&2
        echo "$0 TARGET_BRANCH" >&2
        exit 1
    fi
    if [ "$TARGET_REPO_PATH" = "" ]; then
        echo "Error: TARGET_REPO_PATH is not set in env:" >&2
        exit 1
    fi
    TARGET_BRANCH=$1

    echo "Target repo at:   $TARGET_REPO_PATH"
    echo "Migration branch: $TARGET_BRANCH"
    echo
    cd "$TARGET_REPO_PATH"
    if ! git rev-parse --quiet --verify "$TARGET_BRANCH" >/dev/null; then
        echo "Branch $TARGET_BRANCH does not exist" >&2
        exit 1
    fi
    git_status=$(git status --short)
    if [ -n "$git_status" ]; then
        echo -n "Changes detected, this script is designed to work from a clean state. " >&2
        git status >&2
        echo "Commit/stash changes and try again." >&2
        exit 1
    fi

    echo "This will rebase this branch onto $TARGET_TRUNK_BRANCH and attempt push to $TARGET_REMOTE!"
    confirm_or_exit

    git fetch --no-tags "$TARGET_REMOTE"
    trunk_behind_remote=$(git rev-list --left-only --count "$TARGET_REMOTE/$TARGET_TRUNK_BRANCH...$TARGET_TRUNK_BRANCH")
    if [ "$trunk_behind_remote" != 0 ]; then
        echo "$TARGET_TRUNK_BRANCH is $trunk_behind_remote behind $TARGET_REMOTE/$TARGET_TRUNK_BRANCH. pulling $TARGET_TRUNK_BRANCH"
        git checkout "$TARGET_TRUNK_BRANCH"
        git pull
    else
        echo "OK: $TARGET_TRUNK_BRANCH is up to date with $TARGET_REMOTE/$TARGET_TRUNK_BRANCH"
    fi
    target_behind_trunk=$(git rev-list --left-only --count "$TARGET_REMOTE/$TARGET_TRUNK_BRANCH...$TARGET_BRANCH")
    if [ "$target_behind_trunk" != 0 ]; then
        echo "ERROR: $TARGET_BRANCH is $target_behind_trunk behind $TARGET_REMOTE/$TARGET_TRUNK_BRANCH." >&2
        echo "       Suggested steps:" >&2
        echo "       1. delete migration branch (git branch -D $TARGET_BRANCH)" >&2
        echo "       2. make sure trunk is up to date (git switch $TARGET_TRUNK_BRANCH && git pull)" >&2
        echo "       3. run import-repo.sh again" >&2
        echo "       4. run merge-import.sh again" >&2
        exit 1
    else
        echo "OK: $TARGET_BRANCH is up to date with $TARGET_TRUNK_BRANCH"
    fi


    echo "Rebasing $TARGET_BRANCH onto $TARGET_TRUNK_BRANCH"
    git checkout "$TARGET_TRUNK_BRANCH"
    git rebase "$TARGET_BRANCH"

    confirm_or_exit "Push to $TARGET_TRUNK_BRANCH right meow"
    git push
}

confirm_or_exit() {
    local confirmation_message=${1:-"Aare you sure"}
    # Spelling is a reference to "Aare you safe?"
    # https://www.bern.ch/themen/sicherheit/pravention/aare-you-safe-english/project
    read -r -p "$confirmation_message (y/n)? " choice
    case "$choice" in
        y|Y ) ;;
        * ) echo "Fine we stop here."; exit;;
    esac
}

end_report() {
    local error_code=${?}
    if [ $error_code -ne 0 ]; then
        echo "Some tips" >&2
        echo "git status # should give a clue of the state" >&2
        echo "git rebase --abort # will back out if one of the rebase failed" >&2
    fi
    exit ${error_code}
}
trap 'end_report' EXIT

main "$@"
