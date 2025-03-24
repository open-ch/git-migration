# Scripts for git monorepo migration

This set of scripts aims to help in migrating multiple repositories into a single monorepository.
They cover a range of strategies depending if history needs to be kept or not, there is also a helper for
the merge process depending on the features supported by the remote host repository.

The expectation is that some clean up might be on on the incoming repository so the import process
is iterative and can be done locally avoiding destructive side effects on the source and target while
working on any necessary cleanup or tests.

Migrating a repository is intended to take place in roughly 3 steps:
1. Do non destructive and dry-run migrations of the source repository
2. Review migration results
3. Re-run a fresh migration (if needed) and apply the changes to the remote targed

Note: the source remote repository is not modified.

1. [./import-repo.sh](./import-repo.sh) – Automates 3 migration strategies to import package repos
2. [./merge-import.sh](./merge-import.sh) – Handles the final push when hooks are disabled (with pull/rebase if master has newer changes)

## Phase 1: Prepare migration branch and optional cleanup
The preparation includes reviewing the repository to migrate, selecting a migration
strategy and doing some clean up if needed.

First find out which branch is the trunk/latest branch, on older repositories there can
be surprises where a release branch is a head of main or develop is behind main. Avoid
surprises by carefuly choosing which branch to migrate.

Second review the history. Are there a lot of commits? Are the commit messages meaningful? Is
the history worth migrating or is the squash stratagy good enough to only get the code?

Third comes the cleanup:
- Remove large files (accidental commits of binaries in the history e.g.)
- Remove/flatten sub-modules (including in history)

Optionally depending on the size of the repository and desire to migrate history, more clean up
can be done to test history linearization or manualy clean up poor commits ("Fix", "Fix Fix").

## Phase 2: Review migration
Once the prep is done it's time to run the migration scripts, this is non permanant and can
be restarted (or done as a dry-run at first if desired).

It's important to take a look at the migration results, make sure the files are in the expected
location and the commit log looks as expected.

## Phase 3: (Re-run and) Apply migration
This is highly dependent on how the remote repository works. With Github as a remote,
it can be as simple as open a PR and merge.

Depending on the migration strategy and merge options (squash or not) it makes sense
to tweak settings on the repository. For Github while we normally only allow squash
merge, for migrations we temporarily enabled merge commits to retain history and
disabled the option again after migrating.

Our initial migrations happened using Phabricator as a remote repository/code host
it's similar to Sapling SCM. The structure was exotic in that:
* repo-staging.git stored all the working branches,
* repo.git stored only the trunk branch,
* heavy pre-push/pre-merge restrictions were enforced on the server.

**Rebasing on a migration branch usually lead to a mess**. Therefore our proces on that
setup was to block all merges to trunk for all but the 1-2 contributors migrating. Disable the
restrictions for pushing to trunk. Pull the latest code and run a fresh migration, then merge.
This was possible with minimal down time (5-15 minutes) and was done outside peak hours.

Note: it's worth considering the impact on your CI/CD system. Github typically treats
a merge (even with history) as 1 build the merge commit. Phabricator however, with it's
focus on linear history treated each commit merged to trunk as new and could accidentally
lead to a build for each commit in the migrated history. Depending on the setup it is
important to disable build webhooks during migration. And only re-enable them after
the code hosting service has finished processing the commits.

### Remote branch subtree
The import and merge scripts need to be run back to back in order for this
variant to work properly. If a rebase is needed because of a new commit, git
will attempt to re-apply all the commits and declare any conflicts as needing
to be resolved again.

## Example usage

Example using the *"Retain all commits (patch file variant)"* strategy:
```bash
# Define migration config in environment:
export ISSUE_NUMBER="JIRA-####"                          # i.e. JIRA-1234 (used for branch names)
export SOURCE_BRANCH=develop                             # Optional, defaults to main
export SOURCE_REPO_PATH=/path/to/project_name            # Absolute path to source repository
export TARGET_REPO_PATH=/path/to/project_name            # Absolute path to target repository
export TARGET_PATH=pathinrepo/subpath/project_name/      # Path inside repository
export TARGET_TRUNK_BRANCH=develop                       # Optional defaults to main

# This will create a migration/project_name branch on the destination repository
git-migration/import-repo.sh $SOURCE_REPO_PATH $TARGET_PATH
# Check info and confirm, for example:
# Select 3 – remote sub tree with linearisation

# If you need to start again and want to delete the branches locally
git branch -D migration/project_name
# if pushed for review on remote as well
git push origin --delete migration/project_name

# !!! DANGER ZONE !!!
# depending on your workflow this might require elevated priviliges or disabling hooks
git-migration/merge-import.sh migration/project_name
```

## Helpers

The following are helpful to locate large files before a migration:

- [./git-check-filesizes.sh](./git-check-filesizes.sh) – Checks for files/blobs too large to import
    - To run with a custom size `MAX_SIZE_KB=15625 ./git-check-filesizes.sh <repo_path>` (default: 1024kb)
- [./git-find-blob.pm](./git-find-blob.pm) – Helper to identify which commits these file-blobs are from.
    - Uses the blobs detected by the above script: `./git-find-blob.pm <repo_path> <blob>`

To remove large files [bfg-repo-cleaner](https://rtyley.github.io/bfg-repo-cleaner/) with
`java -jar bfg.jar --strip-blobs-bigger-than 1024K $SOURCE_REPO_PATH`
is an effective option if a simple cleanup is possible.
If you need to remove some but keep others and bfg isn't advanced enough you can look into
[git-filter-branch](https://git-scm.com/docs/git-filter-branch).

If there are sub-modules in the repository or in the git history, this will cause
most git hosts to throw file size errors in case file size restrictions are in place.
In order to fix this, the sub-modules will need to be removed from the repository and
its history. An automated way of going about this is with `git-filter-branch`. The
command would go through the entire history commit by commit and remove any mention
of sub-modules in the repository.

In order to anticipate this kind of problem, the git log can be searched in advance
for the use of sub-modules using `git log -p | grep --after-context=3 Subproject`

If any sub-modules are found the following snippet should help you get rid of them.
```bash
export SUBMOD_PATH='path/to/submodules'
```

```bash
git filter-branch -f --prune-empty --tree-filter '
if [[ -n "$(git submodule--helper list)" ]]; then
    git submodule deinit -f $SUBMOD_PATH
    git rm -rf $SUBMOD_PATH && rm -rf $SUBMOD_PATH && git rm -rf .git/modules/$SUBMOD_PATH
    fi
find . -name .gitmodules -delete' HEAD
```
