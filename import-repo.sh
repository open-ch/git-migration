#!/usr/bin/env bash
# shellcheck disable=SC2001,SC2155
set -o errexit
set -o pipefail
set -o nounset
#
# Script to streamline the migration of repositories into a monorepo
#
git_log_format='%C(yellow)%h%Creset%C(auto)%d%Creset %s %Cgreen(%cr) %C(bold blue)%an%Creset'
red=$(tput setaf 1)
yellow=$(tput setaf 3)
bold=$(tput bold)
reset=$(tput sgr0)
ABSOLUTE_DIR_PATH="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
MIGRATION_CONFIRMED=0

# Config options with env override
DRY_RUN=${DRY_RUN:-0}
SKIP_LINEARIZATION=${SKIP_LINEARIZATION:-1}
SKIP_SUBMODULE_CHECK=${SKIP_SUBMODULE_CHECK:-0}
SKIP_CLEANUP=${SKIP_CLEANUP:-0}
GIT_FILTER_REPO_FORCE=${GIT_FILTER_REPO_FORCE:-0}
export MAX_SIZE_KB=${MAX_SIZE_KB:-10240}

main() {
    parseArgs "$@"
    validateGitRepositories
    checkForLargeFilesInSourceGit
    checkForSubmodulesInSourceGit
    checkForChangesInTargetGit
    selectMigrationStrategy

    echo "Source repo at:      ${bold}$SOURCE_REPO_PATH${reset}"
    echo "Source branch:       ${bold}$SOURCE_BRANCH${reset}"
    echo "Target repo at:      ${bold}$TARGET_REPO_PATH${reset}"
    echo "Target branch:       ${bold}$TARGET_BRANCH${reset}"
    echo "Target path in repo: ${bold}$TARGET_SUB_PATH${reset}"
    if [ "$migration_strategy_choice" = 3 ]; then
        echo "Skip Linearization:  ${bold}$SKIP_LINEARIZATION${reset}"
    fi
    requestConfirmation

    cd "$TARGET_REPO_PATH"
    git switch "$TARGET_TRUNK_BRANCH"
    TARGET_COMMIT_COUNT_BEFORE=$(cd "$TARGET_REPO_PATH"; git rev-list --count HEAD)

    case "$migration_strategy_choice" in
        1 ) importStrategySquash;;
        2 ) importStrategyPatch;;
        3 ) importStrategyRemoteBranchSubtree;;
        * ) echo "Unrecognized option $migration_strategy_choice" >&2; exit 1;;
    esac

    compareResultingRepos
    nextStepsInfo
}

parseArgs() {
    if [ "$#" -ne 2 ]; then
        echo "Error: Invalid arguments, correct use:" >&2
        echo "$0 SOURCE_REPO_PATH TARGET_SUB_PATH" >&2
        exit 1
    fi

    export SOURCE_REPO_PATH=$1
    export TARGET_SUB_PATH=$2

    export ISSUE_NUMBER=${ISSUE_NUMBER:-TRIVIAL}

    export SOURCE_REPO_NAME=$(basename "$SOURCE_REPO_PATH")
    export SOURCE_BRANCH=${SOURCE_BRANCH:-main}
    export SOURCE_COMPARE_PATH=$SOURCE_REPO_PATH
    export TARGET_REPO_PATH=${TARGET_REPO_PATH:-}
    export TARGET_REPO_NAME=${TARGET_REPO_PATH##*/}
    export TARGET_BRANCH=${TARGET_BRANCH:-migration/$SOURCE_REPO_NAME}
    export TARGET_TRUNK_BRANCH=${TARGET_TRUNK_BRANCH:-main}

    if [ "$DRY_RUN" -ne 0 ]; then
        export TARGET_REPO_PATH=/tmp/test-migration-repo
        export TARGET_REPO_NAME=${TARGET_REPO_PATH##*/}
        echo "Dry run on, creating tmp target repo"
        createEmptyDryRunRepo
    fi

    if [ "$TARGET_REPO_PATH" = "" ]; then
        echo "Error: TARGET_REPO_PATH is not set in env:" >&2
        exit 1
    fi
}

validateGitRepositories() {
    if [ ! -d "$SOURCE_REPO_PATH" ]; then
        echo "Error: $SOURCE_REPO_PATH not found :(" >&2
        exit 1
    fi

    if [ -d "$TARGET_REPO_PATH/$TARGET_SUB_PATH" ] && [ -n "$(ls -A "$TARGET_REPO_PATH/$TARGET_SUB_PATH")" ]; then
        echo "Error: $TARGET_REPO_PATH/$TARGET_SUB_PATH is not empty" >&2
        exit 1
    fi
}

checkForLargeFilesInSourceGit() {
    local source_repo_has_large_files=0
    source_repo_large_files=$("$ABSOLUTE_DIR_PATH/git-check-filesizes.sh" "$SOURCE_REPO_PATH") || source_repo_has_large_files=$?
    if [ "$source_repo_has_large_files" != 0 ]; then
        echo "$source_repo_large_files" >&2
        exit 1
    fi
}

checkForSubmodulesInSourceGit() {
    local subproject_matches=""
    local matching_commits
    if [ "$SKIP_SUBMODULE_CHECK" -ne 0 ]; then
        return
    fi
    if subproject_matches=$(git -C "$SOURCE_REPO_PATH" log -p | grep --after-context=3 Subproject); then
        echo "${red}Sub modules detected in the git history:${reset}" >&2
        echo "See readme for details on cleaning up sub modules from history," >&2
        echo "to disable the check use SKIP_SUBMODULE_CHECK=1" >&2
        echo "The following commits matched sub module changes:"
        matching_commits=$(echo "$subproject_matches" | awk '$1 == "commit" { print $2 }')
        for commit in ${matching_commits}; do
            git -C "$SOURCE_REPO_PATH" log -1 --pretty=format:'- %h %d %s %cr %an' "$commit"
        done
        exit 1
    fi
}

checkForChangesInTargetGit() {
    local git_status=""
    git_status=$(git -C "$TARGET_REPO_PATH" status --short)
    if [ -n "$git_status" ]; then
        echo "Changes detected in $TARGET_REPO_NAME:" >&2
        git -C "$TARGET_REPO_PATH" status --short
        echo "This script is designed to work from a clean state, commit/stash changes and try again." >&2
        exit 1
    fi
}

selectMigrationStrategy() {
    echo "Migration Strategies in order of recommendation:"
    echo "1. Import as squash (${yellow}${bold}Git history is not kept${reset})"
    echo "2. Import as patch"
    echo "3. Import as remote branch subtree"
    if [ "$SKIP_LINEARIZATION" != 1 ]; then
        echo "    (${yellow}${bold}Git history is linearized, if SKIP_LINEARIZATION=0${reset})"
    fi
    read -r -p "Chose a strategy (1/2/3)? " migration_strategy_choice

    if [ "$migration_strategy_choice" = 1 ]; then
        echo "[${yellow}WARNING${reset}] squash: ${red}${bold}GIT HISTORY WILL NOT BE MIGRATED USING THIS METHOD${reset}"
        echo "          A single commit will be left, full history will be available on source repository but not target."
    elif [[ "$migration_strategy_choice" = 3 && "$SKIP_LINEARIZATION" -eq 0 ]]; then
        echo "[${yellow}WARNING${reset}] remote branch subtree: ${red}${bold}LINEARIZING GIT HISTORY USING THIS METHOD${reset}"
        echo "          Branch commit messages will not be kept, full history will be available on source repository but not target."
    fi
}

requestConfirmation() {
    read -r -p "The above are correct, continue (y/n)? " choice
    case "$choice" in
        y|Y ) ;;
        * ) echo "Alright fine, stopping here"; exit;;
    esac
    MIGRATION_CONFIRMED=1
}

importStrategyRemoteBranchSubtree() {
    local git_filter_repo_opts=()
    local rc=0
    echo "Starting remote branch subtree migration strategy"

    if [ -z "$(which git-filter-repo)" ]; then
        echo "git-filter-repo needs to be installed (https://github.com/newren/git-filter-repo/)" >&2
        exit 1
    fi

    echo "Creating a branch in $SOURCE_REPO_NAME and moving code to $TARGET_SUB_PATH"
    export SOURCE_COMPARE_PATH="$SOURCE_REPO_PATH/$TARGET_SUB_PATH"
    if [ "$GIT_FILTER_REPO_FORCE" -eq 1 ]; then
         git_filter_repo_opts=( '--force' )
    fi
    pushd "$SOURCE_REPO_PATH"
        if [ ! -d "$SOURCE_REPO_PATH/$TARGET_SUB_PATH" ]; then
            echo "Running git-filter-repo to rewrite history into $TARGET_SUB_PATH"
            git filter-repo "${git_filter_repo_opts[@]-}" --to-subdirectory-filter "$TARGET_SUB_PATH" || rc=$?
            if [ "$rc" -ne 0 ]; then
                echo "Note: when git-filter-repo fails because source repo is not 'clean' you can set"
                echo "      GIT_FILTER_REPO_FORCE=1 and rerun the migration, this will add the '--force'"
                echo "      flag to git filter repo."
                return $rc
            fi
        else
            echo "$TARGET_SUB_PATH already exists, assuming git-filter-repo was already applied, skipping."
        fi

        if [ "$(git branch --show-current)" != "$SOURCE_BRANCH" ]; then
            echo "Switching to source branch:"
            git switch "$SOURCE_BRANCH"
        fi

        if [ "$SKIP_LINEARIZATION" -eq 0 ]; then
            echo "Linearizing history:"
            git log --graph --decorate --pretty=format:"$git_log_format" > /tmp/mig-before.log
            # TODO use git filter-repo instead:
            # https://github.com/newren/git-filter-repo/blob/main/contrib/filter-repo-demos/filter-lamely#L88
            # git-replace might be a better alternative
            FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch --parent-filter 'cut -f 2,3 -d " "' --force
            git log --graph --decorate --pretty=format:"$git_log_format" > /tmp/mig-after.log
            echo "  see /tmp/mig-before.log and /tmp/mig-after.log for details."
        fi
    popd

    echo "Preparing target branch"
    if [[ "$(git branch --show-current)" != "$TARGET_BRANCH" ]]; then
        echo "Switching to target branch:"
        git switch -c "$TARGET_BRANCH"
    fi

    echo "Importing to monorepo:"
    source_repo=$(git remote get-url source_repo 2>/dev/null || true)
    if [ -n "$source_repo" ] && [ "$source_repo" != "$SOURCE_REPO_PATH" ]; then
        echo "Error: git remote source_repos already exists but does not matches $SOURCE_REPO_PATH" >&2
        exit 1
    fi
    git remote add source_repo "$SOURCE_REPO_PATH"
    git fetch source_repo --no-tags --no-recurse-submodules --quiet
    git merge --no-commit --allow-unrelated-histories "source_repo/$SOURCE_BRANCH"
    git commit --no-verify --message="[migration] $ISSUE_NUMBER: Scripted migration of $SOURCE_REPO_NAME into $TARGET_SUB_PATH"

    echo "## Import complete."
    echo "If happy and finished with the import you can remove the remote with:"
    echo "    git remote remove source_repo"
}

importStrategySquash() {
    echo "Starting squash migration strategy"

    echo "Preparing $TARGET_BRANCH branch"
    git switch -c "$TARGET_BRANCH"
    mkdir -p "$TARGET_SUB_PATH"

    echo "Copy content into $TARGET_SUB_PATH"
    pushd "$SOURCE_REPO_PATH"
        if [[ "$(git branch --show-current)" != "$SOURCE_BRANCH" ]]; then
            echo "Switching to source branch:"
            git switch "$SOURCE_BRANCH"
        fi
        find . -maxdepth 1 ! \( -name '.git' -o -name '.' \) \
            -exec cp -r {} "$TARGET_REPO_PATH/$TARGET_SUB_PATH/" \;
    popd

    echo "Creating migration commit"
    git add .
    git commit --no-verify --message="[migration] $ISSUE_NUMBER: Scripted import of $SOURCE_REPO_NAME into $TARGET_REPO_NAME"

    echo "## Import complete."
}

importStrategyPatch() {
    echo "Starting patch migration strategy"
    patch_file="$SOURCE_REPO_PATH/migration.patch"
    git_am_options=("--quiet" "--ignore-space-change" "--ignore-whitespace")
    cd "$TARGET_REPO_PATH"

    pushd "$SOURCE_REPO_PATH"
        if [[ "$(git branch --show-current)" != "$SOURCE_BRANCH" ]]; then
            echo "Switching to source branch:"
            git switch "$SOURCE_BRANCH"
        fi
        if [ ! -f "$SOURCE_REPO_PATH/patch" ]; then
            echo "Creating a patch at $SOURCE_REPO_PATH/patch"
            git log --pretty=email --full-index --reverse --binary --remove-empty > "$patch_file"
        else
            echo "Using existing patch, to create a new one remove it with:"
            echo "    rm $SOURCE_REPO_PATH/patch"
        fi
    popd

    if [[ "$(git branch --show-current)" != "$TARGET_BRANCH" ]]; then
        echo "Switching to target branch:"
        git switch -c "$TARGET_BRANCH"
    fi
    mkdir -p "$TARGET_SUB_PATH"

    patch_status=0
    patch_output=$(git am "${git_am_options[@]}" --directory "$TARGET_SUB_PATH" "$patch_file" 2>&1) || patch_status=$?
    sed 's/^/    /' <<< "$patch_output" # Indent output

    patches_empty_skipped=0
    while [ "$patch_status" -ne 0 ]; do
        if [[ "$patch_output" =~ "Patch is empty" ]]; then
            echo "${bold}Skipping empty patch...${reset}"
            patch_status=0
            patch_output=$(git am "${git_am_options[@]}" --skip 2>&1) || patch_status=$?
            sed 's/^/    /' <<< "$patch_output" # Indent output
            patches_empty_skipped=$((patches_empty_skipped+1))
        else
            echo "Unexpected error applying patch (see above)" >&2
            exit 1
        fi
    done
    echo "## Import complete."
    echo "If happy and finished with the import you can delete the patch with:"
    echo "    rm $SOURCE_REPO_PATH/patch"
}

compareResultingRepos() {
    SOURCE_COMMIT_COUNT=$(cd "$SOURCE_REPO_PATH"; git rev-list --count HEAD)
    TARGET_COMMIT_COUNT_AFTER=$(cd "$TARGET_REPO_PATH"; git rev-list --count HEAD)

    echo "New log on on target repo (latest commits):"
    cd "$TARGET_REPO_PATH"
    git log --graph --decorate --pretty=format:"$git_log_format" -n 10

    echo "Commit count comparison:"
    echo "- in source: $SOURCE_COMMIT_COUNT"
    echo "- in target (after): $TARGET_COMMIT_COUNT_AFTER"
    echo "- in target (before): $TARGET_COMMIT_COUNT_BEFORE"
    if [ "${patches_empty_skipped:-0}" -gt 0 ]; then
        echo "- empty patches skipped: $patches_empty_skipped"
    fi
    echo "- Commits added to target: $(( TARGET_COMMIT_COUNT_AFTER - TARGET_COMMIT_COUNT_BEFORE - 1 )) (excluding merge commit)"

    TARGET_TAGS_AFTER=$(cd "$TARGET_REPO_PATH"; git tag | tail -n +2 | wc -l)
    echo "Tags on target (expected: 0): $TARGET_TAGS_AFTER"

    echo  "Diff between folders"
    echo "(for details run diff -Nqbr -x=.git $SOURCE_REPO_PATH $TARGET_REPO_PATH/$TARGET_SUB_PATH)"
    diff --exclude=.git \
         --exclude=migration.patch \
         --unified \
         --recursive \
         --ignore-space-change \
         "$SOURCE_COMPARE_PATH" "$TARGET_REPO_PATH/$TARGET_SUB_PATH"
    # Possible alternatives:
    #    rsync -nav --delete DIR1/ DIR2
    #    diff <( tree dir1 ) <( tree dir2 )
    #    comm <(ls ~/dir-new/) <(ls ~/dir)
}

nextStepsInfo() {
    postMigrationCleanup
    echo
    echo "${bold}Migration script successful, next steps:${reset}"
    echo "- Push branch to target remote for a test:"
    echo "  - git push origin $TARGET_BRANCH"
    echo "- Open a pull request or do a diff to compare against trunk"
    echo "- Proceed with the merge via PR or via merge-import.sh depending on remote options"
}

failedMigrationCleanup() {
    if [ "$MIGRATION_CONFIRMED" -ne 1 ]; then
        return 0 # Skip prints when migration did not start
    fi
    echo
    echo "${bold}${red}Migration script failed.${reset}"

    if [ "$SKIP_CLEANUP" -eq 1 ]; then
        echo "Skipping error cleanup"
        return 0
    fi
    echo "Running error cleanup (to skip cleanup use SKIP_CLEANUP=1)"

    if [ "$DRY_RUN" -ne 0 ]; then
        echo "- Deleting try run repo from /tmp/test-migration-repo"
        rm -rf /tmp/test-migration-repo
    else
        cd $TARGET_REPO_PATH
        echo "Switching back to main branch"
        git switch $TARGET_TRUNK_BRANCH
        echo "Cleaning import path ($TARGET_SUB_PATH)"
        rm -rf "${TARGET_REPO_PATH:?}/${TARGET_SUB_PATH}"
        echo "Cleaning import branch ($TARGET_BRANCH)"
        git branch -D "$TARGET_BRANCH" || true

        source_repo=$(git remote get-url source_repo 2>/dev/null || true)
        if [ -n "$source_repo" ] && [ "$source_repo" == "$SOURCE_REPO_PATH" ]; then
            echo "Cleaning up migration remote (source_repo)"
            git remote remove source_repo
        fi
    fi
}

postMigrationCleanup() {
    if [ "$MIGRATION_CONFIRMED" -ne 1 ] || [ "$SKIP_CLEANUP" -eq 1 ]; then
        return 0
    fi

    source_repo=$(git remote get-url source_repo 2>/dev/null || true)
    if [ -n "$source_repo" ] && [ "$source_repo" == "$SOURCE_REPO_PATH" ]; then
        echo "Cleaning up migration remote (git remote remove source_repo)"
        git remote remove source_repo
    fi
}

createEmptyDryRunRepo() {
    if [ -d "$TARGET_REPO_PATH/.git" ]; then
        echo "skip test repo creation: already exists"
        return 0
    fi

    mkdir -p $TARGET_REPO_PATH
    cd $TARGET_REPO_PATH
    git init --initial-branch="$TARGET_TRUNK_BRANCH"
    touch .gitignore
    git add .gitignore
    git commit -m "initial commit" --quiet
}

error_report() {
    local error_code=${?}
    echo "Error in function ${1} on line ${2}" >&2
    exit ${error_code}
}
trap 'error_report "${FUNCNAME:-.}" ${LINENO}' ERR

end_report() {
    local error_code=${?}
    if [ "$error_code" -ne "0" ]; then
        failedMigrationCleanup
    fi
    exit ${error_code}
}
trap 'end_report' EXIT

main "$@"
