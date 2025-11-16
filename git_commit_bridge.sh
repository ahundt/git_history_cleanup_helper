#!/bin/bash

# ==============================================================================
# Git Commit Bridge Script (Patch File Transfer)
#
# Purpose: Transfers commits between machines when only one repository can push/pull
#          to the server (workaround for single-repo access restrictions).
#
# CORRECT Workflow Example:
#
#   Machine 1 (restricted - can ONLY push to carrier-repo):
#     1. Develop in my-project (your project - CANNOT push to server)
#     2. EXPORT: my-project → carrier-repo (commits converted to .patch files)
#     3. PUSH carrier-repo to server (the ONE repo Machine 1 can push)
#
#   Machine 2 (unrestricted - can push to any server):
#     4. PULL carrier-repo from server (downloads the .patch files)
#     5. IMPORT: carrier-repo → my-project (recreates commits from patches)
#     6. PUSH my-project to project server (SUCCESS!)
#
# Key Understanding:
#   - my-project and carrier-repo are DIFFERENT projects (no shared commit history)
#   - carrier-repo is just a "messenger" - stores .patch files temporarily
#   - parent_sha in JSON shows which my-project commit the patch came from
#   - Validation checks if Machine 2's my-project has that parent commit
#
# Repository Roles:
#   REPO1 = Carrier repository - can push/pull on Machine 1
#   REPO2 = Project repository - your actual development code
# ==============================================================================

# --- Configuration ---
RANDOM_SUFFIX="01WqaAvCxRr6eWW2Wu33e8xP"
TEMP_BRANCH_BASE="claude"
TRANSFER_DIR=".bridge-transfer" # Dedicated directory inside REPO 1 root for transfer files
TRANSFER_FILE_PREFIX="commit"
ENABLE_AUTO_STASH=false  # Safe by default: require explicit --stash flag
REMOTE_NAME="origin"     # Default remote name (can be overridden with --remote flag)
# --- End Configuration ---

# Function to inform user about stashes and temp files on error
# Provides CONCRETE, ACTIONABLE guidance instead of automatic operations
inform_cleanup_needed() {
    local any_stashes=false

    echo "" >&2
    echo "=======================================================" >&2
    echo "⚠️  CLEANUP NEEDED BEFORE RETRY" >&2
    echo "=======================================================" >&2

    # Check if any stashes were created and inform user with EXACT commands
    for repo_var in $(compgen -v | grep "^STASHED_"); do
        if [[ "${!repo_var}" == "true" ]]; then
            any_stashes=true
            local path_var="${repo_var/STASHED_/STASH_REPO_PATH_}"
            local msg_var="${repo_var/STASHED_/STASH_MESSAGE_}"
            local repo_path="${!path_var}"
            local stash_msg="${!msg_var}"

            if [[ -n "$repo_path" && -n "$stash_msg" ]]; then
                echo "" >&2
                echo "Stashed changes in: $repo_path" >&2
                echo "  Stash: $stash_msg" >&2
                echo "" >&2
                echo "To restore:" >&2
                echo "  cd $repo_path" >&2
                echo "  git stash list | grep git_commit_bridge   # Find your stash" >&2
                echo "  git stash pop stash@{N}                   # Restore (N = stash index)" >&2
                echo "" >&2
            fi
        fi
    done

    # If we're in an export operation and temp directory exists, inform user
    if [[ -n "${temp_work_dir:-}" ]] && [[ -d "${temp_work_dir:-}" ]]; then
        echo "Temporary files preserved for debugging at:" >&2
        echo "  $temp_work_dir" >&2
        echo "" >&2
        echo "To inspect or remove:" >&2
        echo "  ls -lR $temp_work_dir                      # Inspect" >&2
        echo "  rm -rf $temp_work_dir                      # Remove when done" >&2
        echo "" >&2
    fi

    if [[ "$any_stashes" == "true" ]]; then
        echo "IMPORTANT: Restore your stashes before re-running the script." >&2
    fi
    echo "=======================================================" >&2
    echo "" >&2
}

# Function to display error message and exit
error_exit() {
    echo -e "\n======================================================="
    echo -e "!!! ERROR: $1" >&2
    echo -e "======================================================="

    # Inform user about cleanup needed (stashes and temp files)
    # This is INFORMATIVE, not automatic - respects user control
    inform_cleanup_needed

    exit 1
}

# Function to check for required utility (jq)
check_dependencies() {
    command -v jq >/dev/null 2>&1 || error_exit "Required dependency 'jq' not found. Please install 'jq' (JSON processor) to handle metadata."
}

# ==============================================================================
# Robust Stashing System
# ==============================================================================
# Automatically stashes uncommitted/untracked files before operations and restores
# them afterward. Designed to be "easy to use correctly, hard to use incorrectly."
#
# Key Features:
# - Unique ID per stash (PID + timestamp + random) prevents conflicts
# - Works with existing user stashes (doesn't pop wrong ones)
# - Handles multiple script runs safely (each gets unique ID)
# - Detects orphaned stashes from previous failed runs
# - Uses absolute paths to handle same-named repos in different locations
# - Searches by ID instead of assuming stash index
# - Graceful handling of manual user intervention
# - Detailed error messages with recovery instructions
#
# Edge Cases Handled:
# - Clean repository (no stash created)
# - Existing user stashes (ID-based targeting)
# - Multiple bridge stashes from failed runs (unique IDs + warnings)
# - User manually pops stash during operation (detected and skipped)
# - Stash restore conflicts (preserved with recovery steps)
# - Same repo name in different paths (absolute path keys)
# - Stash index changes during operation (search by ID)
# - Repository moved/deleted (graceful error handling)
# ==============================================================================

# Function to check for uncommitted changes
# The EXPORT source (REPO 2) MUST be clean, as the transfer starts from a commit.
# If untracked or uncommitted files exist, automatically stash them with a warning.
# Parameters:
#   $1: repo_path - path to repository
#   $2: operation - "export", "import", or role like "source", "holder", "destination"
check_clean_working_directory() {
    local repo_path="$1"
    local operation="${2:-bridge}"  # Default to "bridge" if not specified
    local repo_name
    repo_name=$(basename "$repo_path")

    cd "$repo_path" || error_exit "Could not change directory to $repo_path. Please check the path."

    if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        error_exit "Path '$repo_path' is not a valid Git repository."
    fi

    # Check for orphaned stashes from previous runs before we create a new one
    warn_about_orphaned_stashes "$repo_path"

    # Check for uncommitted or untracked work
    local git_status
    git_status=$(git status --porcelain)
    if [[ -n "$git_status" ]]; then

        # If auto-stash is NOT enabled, provide actionable error message and exit
        if [[ "$ENABLE_AUTO_STASH" != "true" ]]; then
            echo "" >&2
            echo "=======================================================" >&2
            echo "❌ ERROR: Repository '$repo_name' has uncommitted or untracked files" >&2
            echo "=======================================================" >&2
            echo "$git_status" >&2
            echo "" >&2
            echo "This script requires a clean working directory to ensure safe operation." >&2
            echo "" >&2
            echo "You have 3 options:" >&2
            echo "" >&2
            echo "1. [RECOMMENDED] Review and commit changes following your project's policies:" >&2
            echo "   cd $repo_path" >&2
            echo "   git status                    # Review what changed" >&2
            echo "   # Update .gitignore if needed for files that shouldn't be tracked" >&2
            echo "   git add <specific-files>      # Add only the files you intend to commit" >&2
            echo "   git commit -m \"message\"       # Commit with descriptive message" >&2
            echo "" >&2
            echo "2. Manually stash your changes:" >&2
            echo "   cd $repo_path" >&2
            echo "   git stash push --include-untracked -m \"Description of changes\"" >&2
            echo "   # Run the bridge script" >&2
            echo "   # Then restore: git stash pop" >&2
            echo "" >&2
            echo "3. Use automatic stashing (USE WITH CAUTION):" >&2
            echo "   Add --stash flag to your command:" >&2
            echo "   $0 [mode] [args...] --stash" >&2
            echo "" >&2
            echo "   With --stash, ALL uncommitted and untracked changes will be" >&2
            echo "   automatically stashed before the operation and restored afterward." >&2
            echo "   This is convenient but bypasses your review of what's being stashed." >&2
            echo "=======================================================" >&2
            echo "" >&2
            error_exit "Clean working directory required. Use one of the options above."
        fi

        # Auto-stash is enabled - proceed with automatic stashing
        echo "" >&2
        echo "=======================================================" >&2
        echo "⚠️  AUTO-STASH ENABLED: Repository '$repo_name' has uncommitted or untracked files" >&2
        echo "=======================================================" >&2
        echo "$git_status" >&2
        echo "" >&2
        echo "These changes will be automatically stashed and restored after the operation." >&2
        echo "=======================================================" >&2
        echo "" >&2

        # Get current branch for context
        local current_branch
        current_branch=$(get_current_branch)

        # Generate a short unique ID (first 8 chars of hash)
        local unique_id
        unique_id=$(echo "$$-$(date +%s)-${RANDOM}" | md5sum 2>/dev/null | cut -c1-8 || echo "$$-${RANDOM}")

        # Create human-readable stash message with full context
        # Format: git_commit_bridge[operation]: repo@branch (timestamp) [ID:xyz123]
        local timestamp
        timestamp=$(date '+%Y_%m_%d_%H_%M_%S')
        local stash_message="git_commit_bridge[$operation]: ${repo_name}@${current_branch} ($timestamp) [ID:${unique_id}]"

        # Get current stash count BEFORE creating our stash
        local stash_count_before
        stash_count_before=$(git stash list | wc -l | tr -d ' ')

        # Stash both tracked changes and untracked files
        if ! git stash push --include-untracked -m "$stash_message" > /dev/null 2>&1; then
            error_exit "Failed to stash uncommitted changes in '$repo_name'. Please manually commit or stash them."
        fi

        # Verify the stash was created
        local stash_count_after
        stash_count_after=$(git stash list | wc -l | tr -d ' ')
        if [ "$stash_count_after" -le "$stash_count_before" ]; then
            error_exit "Stash creation appeared to succeed but stash count did not increase. Manual intervention needed."
        fi

        # Find the exact index of our newly created stash (should be stash@{0} but verify)
        local our_stash_index=""
        local idx=0
        while IFS= read -r stash_entry; do
            if echo "$stash_entry" | grep -q "$unique_id"; then
                our_stash_index=$idx
                break
            fi
            idx=$((idx + 1))
        done < <(git stash list)

        if [ -z "$our_stash_index" ]; then
            error_exit "Created stash but could not locate it in stash list. Manual intervention needed."
        fi

        echo "✅ Changes stashed successfully at stash@{$our_stash_index}" >&2
        echo "   Stash: $stash_message" >&2
        echo "" >&2

        # Store stash information using absolute repo path to handle same-named repos in different locations
        local repo_path_normalized
        repo_path_normalized=$(cd "$repo_path" && pwd)
        local repo_key="${repo_path_normalized//[^a-zA-Z0-9]/_}"

        eval "STASHED_${repo_key}=true"
        eval "STASH_UNIQUE_ID_${repo_key}='$unique_id'"
        eval "STASH_REPO_PATH_${repo_key}='$repo_path_normalized'"
        eval "STASH_MESSAGE_${repo_key}='$stash_message'"
    fi
}

# Function to restore stashed changes if they were auto-stashed
# Uses unique stash ID to precisely target the correct stash even with multiple existing stashes
restore_stashed_changes() {
    local repo_path="$1"

    # Normalize the repo path to match how it was stored
    local repo_path_normalized
    if ! repo_path_normalized=$(cd "$repo_path" 2>/dev/null && pwd); then
        echo "⚠️  WARNING: Could not access directory $repo_path to restore stash" >&2
        echo "If you stashed changes there, navigate to the repository and check 'git stash list'." >&2
        return 1
    fi

    local repo_name
    repo_name=$(basename "$repo_path_normalized")
    local repo_key="${repo_path_normalized//[^a-zA-Z0-9]/_}"
    local stash_flag_var="STASHED_${repo_key}"
    local stash_id_var="STASH_UNIQUE_ID_${repo_key}"

    # Check if we stashed changes for this repository
    if [[ "${!stash_flag_var}" != "true" ]]; then
        return 0  # Nothing to restore
    fi

    cd "$repo_path_normalized" || {
        echo "⚠️  WARNING: Could not change to directory $repo_path_normalized to restore stash" >&2
        echo "Your changes are saved in a stash. Navigate there and run:" >&2
        echo "  git stash list  # Find the stash with ID: ${!stash_id_var}" >&2
        echo "  git stash pop stash@{N}  # Where N is the stash index" >&2
        return 1
    }

    local unique_id="${!stash_id_var}"

    echo "" >&2
    echo "=======================================================" >&2
    echo "📦 Restoring stashed changes in '$repo_name'..." >&2
    echo "   Looking for stash ID: $unique_id" >&2
    echo "=======================================================" >&2

    # Find the exact stash index by searching for our unique ID
    local our_stash_index=""
    local idx=0
    while IFS= read -r stash_entry; do
        if echo "$stash_entry" | grep -q "$unique_id"; then
            our_stash_index=$idx
            break
        fi
        idx=$((idx + 1))
    done < <(git stash list 2>/dev/null)

    if [ -z "$our_stash_index" ]; then
        echo "ℹ️  Stash not found (may have been manually restored or dropped already)" >&2
        echo "   Current stashes:" >&2
        git stash list | head -5 >&2 || echo "   (none)" >&2
        echo "=======================================================" >&2
        echo "" >&2
        return 0
    fi

    echo "   Found at: stash@{$our_stash_index}" >&2
    echo "" >&2

    # Pop the specific stash by index (not just the top one!)
    local pop_output
    if pop_output=$(git stash pop --index "stash@{$our_stash_index}" 2>&1); then
        echo "✅ Stashed changes restored successfully" >&2

        # Clear the stash flag now that it's been successfully restored
        # This makes the function truly idempotent - safe to call multiple times
        eval "STASHED_${repo_key}=false"
    else
        # Check if the error is due to conflicts
        if echo "$pop_output" | grep -qi "conflict"; then
            echo "⚠️  WARNING: Stash restore encountered conflicts" >&2
            echo "" >&2
            echo "$pop_output" >&2
            echo "" >&2
            echo "Your changes are still saved in stash@{$our_stash_index}" >&2
            echo "The stash remains in the list because conflicts prevented automatic merge." >&2
            echo "" >&2
            echo "To manually restore:" >&2
            echo "  Option A - Resolve conflicts:" >&2
            echo "    1. Resolve the conflicts shown above in your editor" >&2
            echo "    2. Run 'git add <resolved-files>'" >&2
            echo "    3. Run 'git stash drop stash@{$our_stash_index}' to remove the stash" >&2
            echo "" >&2
            echo "  Option B - Start over (CAUTION: discards conflict resolution):" >&2
            echo "    1. Run 'git checkout -- .' to discard current conflict markers" >&2
            echo "    2. Run 'git stash apply stash@{$our_stash_index}' to retry" >&2
            echo "    3. Manually resolve conflicts if they occur again" >&2
        else
            echo "⚠️  WARNING: Could not auto-restore stash" >&2
            echo "" >&2
            echo "Error output:" >&2
            echo "$pop_output" >&2
            echo "" >&2
            echo "Your changes are still saved in stash@{$our_stash_index}" >&2
            echo "Run 'git stash pop stash@{$our_stash_index}' to manually restore them." >&2
        fi
    fi
    echo "=======================================================" >&2
    echo "" >&2
}

# Function to warn about orphaned auto-stashes from previous failed runs
# This helps users understand if there are leftover stashes that need attention
warn_about_orphaned_stashes() {
    local repo_path="$1"

    cd "$repo_path" 2>/dev/null || return 0

    # Look for any stashes that match our auto-stash pattern
    local orphaned_stashes
    orphaned_stashes=$(git stash list 2>/dev/null | grep "git_commit_bridge\[" || true)

    if [ -n "$orphaned_stashes" ]; then
        local count
        count=$(echo "$orphaned_stashes" | wc -l | tr -d ' ')
        echo "" >&2
        echo "=======================================================" >&2
        echo "ℹ️  NOTICE: Found $count orphaned auto-stash(es) from previous runs" >&2
        echo "=======================================================" >&2
        echo "$orphaned_stashes" >&2
        echo "" >&2
        echo "These are likely from previous script runs that were interrupted." >&2
        echo "They will not interfere with this run (each stash has a unique ID)." >&2
        echo "" >&2
        echo "To clean up manually:" >&2
        echo "  git stash list                    # View all stashes" >&2
        echo "  git stash drop stash@{N}          # Drop specific stash" >&2
        echo "  git stash clear                   # Remove ALL stashes (use with caution!)" >&2
        echo "=======================================================" >&2
        echo "" >&2
    fi
}

# Function to get the current branch name
get_current_branch() {
    git rev-parse --abbrev-ref HEAD
}

# Function to count unpushed commits (for auto-mode)
get_unpushed_commit_count() {
    local repo_path="$1"
    cd "$repo_path" || return 1

    local current_branch
    current_branch=$(get_current_branch)
    local upstream_branch
    upstream_branch=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)

    if [ -z "$upstream_branch" ]; then
        echo "0"
        return 1
    fi

    local count
    count=$(git rev-list --count "$upstream_branch"..HEAD 2>/dev/null || echo "0")
    echo "$count"
    return 0
}

# Function to find bridge branches (for auto-mode)
find_bridge_branches() {
    local repo_path="$1"
    cd "$repo_path" || return 1

    git fetch origin --quiet 2>/dev/null || true
    git branch -r | grep "origin/${TEMP_BRANCH_BASE}/" | sed 's/.*origin\///' | grep "${RANDOM_SUFFIX}$" || true
}

# Function to auto-detect operation mode
auto_detect_mode() {
    local repo1_path="$1"
    local _repo2_path="$2"  # Unused but part of function signature

    # Check if REPO1 has bridge branches (indicates IMPORT scenario)
    cd "$repo1_path" || return 1
    local bridge_branches
    bridge_branches=$(find_bridge_branches "$repo1_path")

    if [ -n "$bridge_branches" ]; then
        echo "IMPORT"
        return 0
    fi

    # Check if REPO1 has unpushed commits (indicates EXPORT scenario)
    local unpushed
    unpushed=$(get_unpushed_commit_count "$repo1_path")
    if [ "$unpushed" -gt 0 ]; then
        echo "EXPORT"
        return 0
    fi

    # Check if REPO1 has commits (even without upstream)
    cd "$repo1_path" || return 1
    if git rev-parse HEAD >/dev/null 2>&1; then
        echo "EXPORT"
        return 0
    fi

    echo "UNKNOWN"
    return 1
}

# ==============================================================================
# MODE 1: EXPORT (Source -> Holder/Remote)
# USAGE: ./git_commit_bridge.sh export <REPO 2 SRC PATH> <REPO 1 HOLDER PATH> [N COMMITS]
# ==============================================================================
do_export() {
    local repo2_src_path="$1"
    local repo1_holder_path="$2"
    # Optional third argument for number of commits
    local num_commits="$3"

    check_dependencies

    # Auto-calculate commit count if not provided or "auto"
    if [ -z "$num_commits" ] || [ "$num_commits" == "auto" ]; then
        echo "==> Auto-calculating commit count from upstream..." >&2
        num_commits=$(get_unpushed_commit_count "$repo2_src_path")

        if [ "$num_commits" -eq 0 ]; then
            echo "WARNING: No unpushed commits detected. Using last 1 commit." >&2
            num_commits=1
        else
            echo "INFO: Found $num_commits unpushed commit(s)" >&2
        fi
    fi

    echo "--- Starting EXPORT: Transferring last $num_commits commit(s) from REPO 2 (Source) via REPO 1 (Holder) ---"

    # --- Validation and Pre-checks ---

    # Check REPO 2 (The SOURCE repository) - Must be clean
    check_clean_working_directory "$repo2_src_path" "export-source"
    local repo2_original_branch
    repo2_original_branch=$(get_current_branch)

    # Check REPO 1 (The PUSHING/HOLDER repository)
    check_clean_working_directory "$repo1_holder_path" "export-holder"
    local repo1_original_branch
    repo1_original_branch=$(get_current_branch)

    echo "INFO: REPO 2 Source path: $repo2_src_path (Branch: $repo2_original_branch)"
    echo "INFO: REPO 1 Holder path: $repo1_holder_path (Branch: $repo1_original_branch)"

    cd "$repo2_src_path" || error_exit "Could not change directory to $repo2_src_path"
    local head_commit
    head_commit=$(git rev-parse HEAD)

    if [ -z "$head_commit" ]; then
        error_exit "REPO 2 ($repo2_src_path) has no commits. Cannot export."
    fi

    # Construct the unique, safe temporary branch name
    local temp_branch="${TEMP_BRANCH_BASE}/${repo2_original_branch}-${RANDOM_SUFFIX}"
    echo "INFO: Using temporary branch name: ${temp_branch}"

    # Create a temporary working directory for file generation
    local temp_work_dir="/tmp/git_bridge_export_$$"
    mkdir -p "$temp_work_dir/$TRANSFER_DIR" || error_exit "Failed to create temporary directory for patch generation."

    echo "INFO: Temporary files will be created in: $temp_work_dir"

    # --- Core Transfer Logic ---

    echo -e "\n1. Generating $num_commits ordered patch and metadata files..."

    # Get the list of the last N commit SHAs, OLDEST FIRST (--reverse)
    local commit_list=()
    mapfile -t commit_list < <(git rev-list --max-count="$num_commits" --abbrev-commit --reverse HEAD)
    local total_generated=0
    local commit_index=1 # Start index at 1 for chronological ordering

    for commit_sha in "${commit_list[@]}"; do
        local short_sha
        short_sha=$(echo "$commit_sha" | cut -c 1-7)
        local parent_sha
        parent_sha=$(git rev-parse "$commit_sha"^ 2>/dev/null)
        local index_str
        index_str=$(printf "%03d" $commit_index) # Zero-padded index (001, 002, ...)

        # Determine the diff range: If it's the first commit, diff against the empty tree object.
        # This prevents issues when transferring the root commit of a repository.
        if [ -z "$parent_sha" ]; then
            # Diff against an empty tree for the very first commit in history
            local diff_range="4b825dc642cb6eb9a060e54bf8d69288fbee4904..$commit_sha"
        else
            local diff_range="$parent_sha..$commit_sha"
        fi

        # Generate the Patch File (.patch) - Naming format: 001_commit_SHA.patch
        local patch_filename="${index_str}_${TRANSFER_FILE_PREFIX}_${short_sha}.patch"
        git show "$diff_range" --binary > "$temp_work_dir/$TRANSFER_DIR/$patch_filename" || error_exit "Failed to generate patch for SHA $short_sha."

        # Generate the Metadata File (.json) - Naming format: 001_commit_SHA.json
        local json_filename="${index_str}_${TRANSFER_FILE_PREFIX}_${short_sha}.json"

        # Extract commit metadata using git log, then properly encode as JSON using jq
        local commit_sha_full
        commit_sha_full=$(git log -1 --pretty=format:'%H' "$commit_sha")
        local author_name
        author_name=$(git log -1 --pretty=format:'%an' "$commit_sha")
        local author_email
        author_email=$(git log -1 --pretty=format:'%ae' "$commit_sha")
        local date_full
        date_full=$(git log -1 --pretty=format:'%aI' "$commit_sha")
        local commit_subject
        commit_subject=$(git log -1 --pretty=format:'%s' "$commit_sha")
        local commit_body
        commit_body=$(git log -1 --pretty=format:'%b' "$commit_sha")

        # Use jq to properly encode all values as JSON (handles special characters and escaping)
        # Include parent_sha for import validation
        jq -n \
            --arg sha "$commit_sha_full" \
            --arg parent_sha "${parent_sha:-}" \
            --arg author_name "$author_name" \
            --arg author_email "$author_email" \
            --arg date_full "$date_full" \
            --arg commit_subject "$commit_subject" \
            --arg commit_body "$commit_body" \
            '{sha: $sha, parent_sha: $parent_sha, author_name: $author_name, author_email: $author_email, date_full: $date_full, commit_subject: $commit_subject, commit_body: $commit_body}' \
            > "$temp_work_dir/$TRANSFER_DIR/$json_filename" || error_exit "Failed to generate metadata for SHA $short_sha."

        total_generated=$((total_generated + 1))
        commit_index=$((commit_index + 1)) # Increment index
        echo "   -> Generated files for commit: $short_sha (Index: $index_str)"
    done

    if [ "$total_generated" -eq 0 ]; then
        error_exit "No patches were generated. Check the commit history in REPO 2."
    fi


    # 2. Commit the patch/metadata files to the temp branch in REPO 1
    echo -e "\n2. Committing $total_generated transfer file pair(s) into temporary branch in REPO 1 Holder..."

    # Check out REPO 1 Holder
    cd "$repo1_holder_path" || error_exit "Could not change directory to $repo1_holder_path"

    # Check if REPO 1 has an 'origin' remote defined
    if ! git remote -v | grep -q 'origin'; then
        error_exit "REPO 1 ($repo1_holder_path) does not have a remote named 'origin'. Cannot push to GitHub."
    fi

    # Fetch to ensure the base for the new branch is up-to-date
    git fetch origin || error_exit "Failed to fetch remote for REPO 1. Check network connection."

    # Create the temporary branch starting from origin/HEAD
    git checkout -b "$temp_branch" "origin/$(get_current_branch)" 2>/dev/null || \
    git checkout -b "$temp_branch" || error_exit "Failed to create temporary branch in REPO 1."

    # Copy generated files into REPO 1's working directory
    cp -r "$temp_work_dir/$TRANSFER_DIR" . || error_exit "Failed to copy transfer directory."

    # Commit the files
    git add "$TRANSFER_DIR"
    git commit -m "Bridge: Transfer of $total_generated commit(s) from ${repo2_original_branch}" || error_exit "Failed to create commit in REPO 1."

    # Get the commit SHA for reference
    local bridge_commit
    bridge_commit=$(git rev-parse HEAD)

    # 3. Return to original branch and clean up temp work directory
    echo -e "\n3. Cleaning up local workspace in REPO 1 Holder..."
    git checkout "$repo1_original_branch" || error_exit "Failed to return to original branch in REPO 1. Manual intervention needed."

    # Only remove temp directory on success - if we got here, everything worked
    echo "   Removing temporary directory: $temp_work_dir"
    rm -rf "$temp_work_dir"

    # 4. Restore any stashed changes in both repositories
    restore_stashed_changes "$repo1_holder_path"
    restore_stashed_changes "$repo2_src_path"

    echo -e "\n✅ EXPORT SUCCESSFUL."
    echo "======================================================="
    echo "Bridge branch created: ${temp_branch}"
    echo "Bridge commit: ${bridge_commit}"
    echo "======================================================="
    echo ""
    echo "NEXT STEPS:"
    echo ""
    echo "1. Push the bridge branch to make it available for import:"
    echo "   cd $repo1_holder_path"
    echo "   git push origin $temp_branch"
    echo ""
    echo "2. On the destination machine, run import:"
    echo "   $0 import <BRIDGE_REPO> <DEST_REPO>"
    echo ""
    echo "3. After successful import, clean up the bridge branch:"
    echo "   $0 cleanup $repo1_holder_path $temp_branch"
    echo "======================================================="
}

# ==============================================================================
# MODE 2: IMPORT (Remote -> Destination)
# USAGE: ./git_commit_bridge.sh import <BRIDGE_REPO_PATH> <DEST_REPO_PATH> [TEMP_BRANCH_NAME]
# ==============================================================================
do_import() {
    local repo1_bridge_path="$1"
    local repo2_dest_path="$2"
    local temp_branch="$3"

    check_dependencies

    # Validate bridge repo path
    if [[ -z "$repo1_bridge_path" ]]; then
        error_exit "Bridge repository path is required for import mode."
    fi

    # Auto-find bridge branch if not provided
    if [[ -z "$temp_branch" ]]; then
        echo "==> Auto-finding bridge branch..." >&2

        # Find bridge branches in the bridge repo
        local bridge_branches
        bridge_branches=$(find_bridge_branches "$repo1_bridge_path")

        if [ -z "$bridge_branches" ]; then
            error_exit "No bridge branches found. Please provide branch name manually."
        fi

        local branch_count
        branch_count=$(echo "$bridge_branches" | wc -l)

        if [ "$branch_count" -eq 1 ]; then
            temp_branch=$(echo "$bridge_branches" | head -1)
            echo "INFO: Found 1 bridge branch: $temp_branch" >&2
        else
            # Multiple branches found - print options and exit with instructions
            echo "" >&2
            echo "=======================================================" >&2
            echo "INFO: Found $branch_count bridge branches:" >&2
            echo "=======================================================" >&2
            local branch_index=1
            while IFS= read -r branch; do
                echo "  $branch_index) $branch" >&2
                branch_index=$((branch_index + 1))
            done <<< "$bridge_branches"
            echo "" >&2
            echo "Please re-run with explicit branch selection using one of:" >&2
            echo "" >&2
            while IFS= read -r branch; do
                echo "  $0 import $repo1_bridge_path $repo2_dest_path $branch" >&2
            done <<< "$bridge_branches"
            echo "=======================================================" >&2
            exit 0
        fi
    fi

    echo "--- Starting IMPORT: Applying changes to REPO 2 (Destination) ---"

    # --- Validation and Pre-checks ---

    # Check REPO 1 (The BRIDGE repository)
    if [ ! -d "$repo1_bridge_path/.git" ]; then
        error_exit "Bridge repository path '$repo1_bridge_path' is not a valid Git repository."
    fi

    # Check REPO 2 (The DESTINATION PROJECT repository - where commits will be recreated)
    # This is my-project on Machine 2 (NOT the carrier repo)
    check_clean_working_directory "$repo2_dest_path" "import-destination"
    local repo2_original_branch
    repo2_original_branch=$(get_current_branch)

    echo "INFO: Carrier repository (messenger): $repo1_bridge_path"
    echo "INFO: Project repository (destination): $repo2_dest_path (Branch: $repo2_original_branch)"

    cd "$repo2_dest_path" || error_exit "Could not change directory to $repo2_dest_path"

    # 1. Fetch the bridge branch from the CARRIER repository (has the .patch files)
    echo -e "\n1. Fetching patches from carrier repository..."
    git fetch "$repo1_bridge_path" "$temp_branch" || error_exit "Failed to fetch branch '$temp_branch' from carrier repo. Check repo path and branch name."

    # 2. Check out the transfer files into a temporary local branch IN PROJECT REPO
    # NOTE: Temp branch will be deleted after import - commits go to repo2_original_branch
    local local_temp_branch="local-bridge-$$"
    echo "2. Creating temporary branch in project repo to extract patch files..."
    git checkout -b "$local_temp_branch" FETCH_HEAD --no-track || error_exit "Failed to checkout transfer files."

    if [ ! -d "$TRANSFER_DIR" ]; then
        error_exit "Transfer directory '$TRANSFER_DIR' not found in the fetched branch."
    fi

    # 3. Sort patches by filename (which contains the chronological index) and apply sequentially
    echo -e "\n3. Sorting and applying patches sequentially..."

    # Use find to locate patch files and sort by the 001_, 002_ prefix for correct ordering
    local patch_files_sorted
    patch_files_sorted=$(find "$TRANSFER_DIR" -maxdepth 1 -name '[0-9][0-9][0-9]_'"${TRANSFER_FILE_PREFIX}_"'*.patch' 2>/dev/null | sort)
    local num_patches=0
    local applied_count=0

    # Count the number of patches found
    for _file in $patch_files_sorted; do
        num_patches=$((num_patches + 1))
    done

    if [ "$num_patches" -eq 0 ]; then
        error_exit "No patch files found in the transfer directory."
    fi

    # Iterate over the correctly sorted file list
    for patch_file in $patch_files_sorted; do
        # Extract the SHA from the file name using sed's extended regex for reliability
        # Matches: 001_commit_SHA.patch and captures SHA
        local filename
        filename=$(basename "$patch_file")
        local short_sha
        short_sha=$(echo "$filename" | sed -E "s/^[0-9]+_${TRANSFER_FILE_PREFIX}_([0-9a-fA-F]+)\.patch$/\1/")

        # Construct the JSON file name from the patch file name
        local json_file="${patch_file/.patch/.json}"

        if [ -z "$short_sha" ]; then
            error_exit "Failed to extract SHA from filename: $filename"
        fi

        if [ ! -f "$json_file" ]; then
            error_exit "Missing metadata file $json_file for patch $patch_file."
        fi

        applied_count=$((applied_count + 1))
        echo -e "\n--- Applying and committing patch $applied_count of $num_patches: SHA $short_sha ---"

        # Extract Metadata first for validation
        local author_name
        author_name=$(jq -r '.author_name' "$json_file")
        local author_email
        author_email=$(jq -r '.author_email' "$json_file")
        local date_full
        date_full=$(jq -r '.date_full' "$json_file")
        local commit_subject
        commit_subject=$(jq -r '.commit_subject' "$json_file")
        local commit_body
        commit_body=$(jq -r '.commit_body' "$json_file")
        local parent_sha
        parent_sha=$(jq -r '.parent_sha' "$json_file")

        # Validate critical metadata was extracted successfully
        if [[ -z "$author_name" || "$author_name" == "null" ]]; then
            error_exit "Failed to extract author_name from $json_file"
        fi
        if [[ -z "$author_email" || "$author_email" == "null" ]]; then
            error_exit "Failed to extract author_email from $json_file"
        fi
        if [[ -z "$date_full" || "$date_full" == "null" ]]; then
            error_exit "Failed to extract date_full from $json_file"
        fi
        if [[ -z "$commit_subject" || "$commit_subject" == "null" ]]; then
            error_exit "Failed to extract commit_subject from $json_file"
        fi

        # Validate parent commit exists in DESTINATION project repo (first patch only)
        # NOTE: We're checking the PROJECT repo (my-project), NOT the carrier repo
        # parent_sha is from the source PROJECT repo where patches were created
        # Carrier repo (carrier-repo) doesn't matter - it's just a messenger
        if [[ $applied_count -eq 1 && -n "$parent_sha" && "$parent_sha" != "null" && "$parent_sha" != "" ]]; then
            # Check if parent commit exists in destination PROJECT repository
            # This validation happens in repo2_dest_path (my-project on Machine 2)
            if ! git cat-file -e "$parent_sha" 2>/dev/null; then
                echo "" >&2
                echo "=======================================================" >&2
                echo "❌ ERROR: Project Repository Missing Parent Commit" >&2
                echo "=======================================================" >&2
                echo "First patch expects parent commit: $parent_sha" >&2
                echo "This commit does not exist in destination project repository." >&2
                echo "" >&2
                echo "Patch details:" >&2
                echo "  Subject: $commit_subject" >&2
                echo "  Author: $author_name <$author_email>" >&2
                echo "" >&2
                echo "This usually means:" >&2
                echo "  - Machine 2's project repo is older than Machine 1's" >&2
                echo "  - Machine 2's project repo is on a different branch" >&2
                echo "  - Patches came from a different project entirely" >&2
                echo "" >&2
                echo "To diagnose:" >&2
                echo "  # Check what files the patch tries to modify:" >&2
                echo "  grep '^diff --git' $patch_file | head" >&2
                echo "" >&2
                echo "  # See if those files exist in destination:" >&2
                echo "  ls -la <file-paths-from-above>" >&2
                echo "" >&2
                echo "Destination project repository:" >&2
                echo "  Path: $(pwd)" >&2
                echo "  Branch: $repo2_original_branch" >&2
                echo "" >&2
                echo "Note: Carrier repository doesn't matter - only project repo is validated" >&2
                echo "=======================================================" >&2
                error_exit "Parent commit $parent_sha not found in destination project repository"
            fi
        fi

        # Apply the patch
        git apply --check --whitespace=fix "$patch_file" || error_exit "Patch check failed for $short_sha. Resolve conflicts manually, then run 'git checkout -- $TRANSFER_DIR' to remove transfer files."
        git apply --whitespace=fix "$patch_file" || error_exit "Failed to apply patch for $short_sha. Manual conflict resolution needed."

        # Prepare commit
        git add .

        # Preserve original author details and timestamp (Committer will be the user on Machine 2)
        export GIT_AUTHOR_NAME="$author_name"
        export GIT_AUTHOR_EMAIL="$author_email"
        export GIT_AUTHOR_DATE="$date_full"
        export GIT_COMMITTER_DATE="$date_full"

        local full_message="$commit_subject\n\n$commit_body"

        git commit -F <(echo -e "$full_message") || error_exit "Failed to create final commit for $short_sha. Are there changes to commit?"

        # Unset environment variables to prevent pollution across iterations
        unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_DATE

    done

    # 4. Final cleanup of transfer files and temporary branch
    echo -e "\n4. Final cleanup..."

    # Remove the transfer directory
    rm -rf "$TRANSFER_DIR" || echo "Warning: Failed to remove transfer directory locally."

    # Switch back to original branch
    git checkout "$repo2_original_branch" || error_exit "Failed to return to original branch. Manual intervention needed."

    # Delete temporary branch
    git branch -D "$local_temp_branch" || error_exit "Failed to delete temporary local branch. Manual intervention needed."

    # Restore any stashed changes in the destination repository
    restore_stashed_changes "$repo2_dest_path"

    echo -e "\n✅ IMPORT SUCCESSFUL."
    echo "$applied_count commit(s) have been applied and committed to your current branch ($repo2_original_branch) with full metadata preserved."
    echo ""
    echo "NEXT STEPS:"
    echo ""
    echo "1. [OPTIONAL] Review the imported commits:"
    echo "   git log -${applied_count}    # Review what was just imported"
    echo "   git diff HEAD~${applied_count}    # See all changes"
    echo ""
    echo "2. Push to your remote (when ready):"
    echo "   git push origin $repo2_original_branch"
    echo "   # Or if this is a new branch:"
    echo "   # git push -u origin $repo2_original_branch"
    echo ""
    echo "3. Clean up the bridge branch on the export machine:"
    echo "   (Run this command on the machine where you did the export)"
    echo "   $0 cleanup <BRIDGE_REPO> $temp_branch"
    echo ""
}

# ==============================================================================
# MODE 3: CLEANUP (Holder Cleanup)
# USAGE: ./git_commit_bridge.sh cleanup <REPO 1 HOLDER PATH> <FULL TEMP BRANCH NAME>
# ==============================================================================
do_cleanup() {
    local repo1_holder_path="$1"
    local temp_branch="$2"

    if [[ -z "$temp_branch" ]]; then
        error_exit "Missing temporary branch name. Please provide the full branch name."
    fi

    echo "--- Starting CLEANUP: Deleting transfer branch from REPO 1 Holder ---"
    echo "INFO: Using remote: $REMOTE_NAME"

    # Check REPO 1
    cd "$repo1_holder_path" || error_exit "Could not change directory to $repo1_holder_path"

    # Verify the specified remote exists
    if ! git remote -v | grep -q "^${REMOTE_NAME}\s"; then
        echo ""
        echo "ERROR: Remote '$REMOTE_NAME' not found in this repository."
        echo ""
        echo "Available remotes:"
        git remote -v
        echo ""
        error_exit "Please specify the correct remote with --remote <name> flag."
    fi

    # Check if we're currently on the branch we're trying to delete
    local current_branch
    current_branch=$(get_current_branch)

    if [[ "$current_branch" == "$temp_branch" ]]; then
        echo ""
        echo "⚠️  WARNING: You are currently on branch '$temp_branch'"
        echo "Cannot delete the branch you're currently on."
        echo ""

        # Try to find a safe branch to switch to
        local safe_branch=""
        for branch in main master develop; do
            if git branch --list "$branch" | grep -q "$branch"; then
                safe_branch="$branch"
                break
            fi
        done

        if [[ -z "$safe_branch" ]]; then
            # No standard branch found, get the first non-bridge branch
            safe_branch=$(git branch --list | grep -v "$temp_branch" | head -1 | sed 's/^[* ]*//')
        fi

        if [[ -n "$safe_branch" ]]; then
            echo "Automatically switching to branch '$safe_branch'..."
            git checkout "$safe_branch" || error_exit "Failed to switch away from bridge branch. Please manually checkout another branch first."
            echo "✅ Switched to '$safe_branch'"
        else
            error_exit "No safe branch to switch to. Please manually checkout another branch before running cleanup."
        fi
    fi

    # 1. Delete remote branch
    echo -e "\n1. Deleting remote bridge branch '$temp_branch' from $REMOTE_NAME..."
    git push "$REMOTE_NAME" --delete "$temp_branch" || error_exit "Failed to delete remote branch. Check REPO 1's push access to $REMOTE_NAME."

    # 2. Delete local branch (if it exists)
    if git branch --list "$temp_branch" | grep -q "$temp_branch"; then
        echo "2. Deleting local branch '$temp_branch' from REPO 1..."
        git branch -D "$temp_branch" || echo "Warning: Failed to delete local branch (manual delete may be required)."
    else
        echo "2. Local branch '$temp_branch' not found in REPO 1 (already clean)."
    fi

    echo -e "\n✅ CLEANUP SUCCESSFUL."
    echo "The transfer bridge has been safely removed from both REPO 1 and $REMOTE_NAME."
}

# ==============================================================================
# Main Script Logic
# ==============================================================================

# Parse flags from all arguments
SKIP_NEXT=false
for i in $(seq 1 $#); do
    if [[ "$SKIP_NEXT" == "true" ]]; then
        SKIP_NEXT=false
        continue
    fi

    arg="${!i}"
    case "$arg" in
        --stash)
            ENABLE_AUTO_STASH=true
            ;;
        --remote)
            # Get the next argument as the remote name
            next_i=$((i + 1))
            REMOTE_NAME="${!next_i}"
            SKIP_NEXT=true
            if [[ -z "$REMOTE_NAME" || "$REMOTE_NAME" == --* ]]; then
                error_exit "--remote flag requires a remote name argument (e.g., --remote origin)"
            fi
            ;;
    esac
done

# Parse arguments - detect auto-mode vs manual mode (filter out flags)
args=()
SKIP_NEXT_ARG=false
for arg in "$@"; do
    if [[ "$SKIP_NEXT_ARG" == "true" ]]; then
        SKIP_NEXT_ARG=false
        continue
    fi

    if [[ "$arg" == "--remote" ]]; then
        SKIP_NEXT_ARG=true
        continue
    fi

    if [[ "$arg" != --* ]]; then
        args+=("$arg")
    fi
done

if [[ "${args[0]}" == "export" ]] || [[ "${args[0]}" == "import" ]] || [[ "${args[0]}" == "cleanup" ]]; then
    # Manual mode: explicit mode specified
    MODE="${args[0]}"
    REPO_PATH_1="${args[1]}"
    REPO_PATH_2_OR_BRANCH_NAME="${args[2]}"
    N_COMMITS="${args[3]}"
else
    # Auto mode: first arg is a path, detect mode automatically
    MODE="auto"
    REPO_PATH_1="${args[0]}"
    REPO_PATH_2_OR_BRANCH_NAME="${args[1]}"
    N_COMMITS="${args[2]}"
fi

# Display help if arguments are missing or --help is used
if [ -z "$1" ] || [ "$1" == "--help" ]; then
    echo "======================================================="
    echo "Git Commit Bridge - Robust Cross-Repo Transfer CLI"
    echo "======================================================="
    echo "Transfers committed changes between UNRELATED Git repos via a remote branch,"
    echo "preserving commit order and full metadata (author, date, message)."
    echo "-------------------------------------------------------"
    echo "NOTE: Requires 'jq' utility for JSON processing."
    echo ""

    echo "========== AUTO MODE (Recommended) ==========="
    echo ""
    echo "Automatically detects EXPORT or IMPORT based on repo state:"
    echo ""
    echo "Machine 1 (EXPORT): $0 <SOURCE_REPO> <BRIDGE_REPO> [N_COMMITS]"
    echo "  - Auto-counts unpushed commits if N_COMMITS not specified"
    echo "  - Generates patches and commits to bridge repo (push manually)"
    echo "  Example: $0 ~/my-app ~/cli-bridge"
    echo "  Example: $0 ~/my-app ~/cli-bridge 5"
    echo ""
    echo "Machine 2 (IMPORT): $0 <BRIDGE_REPO> <DEST_REPO>"
    echo "  - Auto-finds bridge branch (exits with options if multiple exist)"
    echo "  - Fetches from bridge repo and applies patches to destination"
    echo "  Example: $0 ~/cli-bridge ~/my-app"
    echo ""
    echo "How auto-detection works:"
    echo "  - EXPORT: First repo has unpushed commits"
    echo "  - IMPORT: First repo (bridge) has bridge branches matching pattern"
    echo ""

    echo "========== MANUAL MODE (Advanced) ==========="
    echo ""
    echo "1. EXPORT (Machine 1: Create Bridge)"
    echo "   Action: Takes last [N] commit(s), packages as patches, commits to bridge repo"
    echo "   Usage: $0 export <SOURCE_REPO> <BRIDGE_REPO> [N_COMMITS=1]"
    echo "   Example: $0 export ~/app ~/bridge 3"
    echo "   Note: You must manually push the bridge branch after export"
    echo ""
    echo "2. IMPORT (Machine 2: Apply Changes)"
    echo "   Action: Fetches from bridge repo, applies patches sequentially with metadata"
    echo "   Usage: $0 import <BRIDGE_REPO> <DEST_REPO> [TEMP_BRANCH_NAME]"
    echo "   Example: $0 import ~/bridge ~/app"
    echo "   Example: $0 import ~/bridge ~/app ${TEMP_BRANCH_BASE}/main-${RANDOM_SUFFIX}"
    echo ""
    echo "3. CLEANUP (Machine 1: Remove Bridge)"
    echo "   Action: Deletes temporary branch from remote and local"
    echo "   Usage: $0 cleanup <HOLDER_REPO> <TEMP_BRANCH_NAME>"
    echo "   Example: $0 cleanup ~/bridge ${TEMP_BRANCH_BASE}/main-${RANDOM_SUFFIX}"
    echo "   Example: $0 cleanup ~/bridge ${TEMP_BRANCH_BASE}/main-${RANDOM_SUFFIX} --remote ahundt"
    echo ""
    echo "========== OPTIONS ==========="
    echo ""
    echo "--stash        Enable automatic stashing of uncommitted/untracked files"
    echo "               (USE WITH CAUTION)"
    echo ""
    echo "               By default, the script requires clean working directories"
    echo "               for safety. Use this flag to automatically stash changes"
    echo "               before operations and restore them afterward."
    echo ""
    echo "               Example: $0 export ~/app ~/bridge 3 --stash"
    echo "               Example: $0 ~/bridge ~/app --stash"
    echo ""
    echo "               IMPORTANT: Without --stash, you'll receive clear error"
    echo "               messages with three options if uncommitted files exist."
    echo ""
    echo "--remote <name> Specify which remote to use for push/delete operations"
    echo "               (Default: origin)"
    echo ""
    echo "               Use this when your repository has multiple remotes and the"
    echo "               bridge branch is not on 'origin'. The script will verify"
    echo "               the remote exists before attempting operations."
    echo ""
    echo "               Example: $0 cleanup ~/bridge my-branch --remote ahundt"
    echo "               Example: $0 export ~/app ~/bridge 3 --remote upstream"
    echo "======================================================="
    exit 0
fi

case "$MODE" in
    auto)
        # Auto mode: detect operation based on repo state
        if [ -z "$REPO_PATH_1" ] || [ -z "$REPO_PATH_2_OR_BRANCH_NAME" ]; then
            error_exit "Auto mode requires two repository paths."
        fi

        echo "==> Auto-detecting operation mode..." >&2
        DETECTED_MODE=$(auto_detect_mode "$REPO_PATH_1" "$REPO_PATH_2_OR_BRANCH_NAME")

        if [ "$DETECTED_MODE" == "EXPORT" ]; then
            echo "INFO: Detected EXPORT mode (source has commits)" >&2
            do_export "$REPO_PATH_1" "$REPO_PATH_2_OR_BRANCH_NAME" "$N_COMMITS"
        elif [ "$DETECTED_MODE" == "IMPORT" ]; then
            echo "INFO: Detected IMPORT mode (bridge has bridge branch)" >&2
            do_import "$REPO_PATH_1" "$REPO_PATH_2_OR_BRANCH_NAME" "" # Bridge repo, dest repo, auto-find branch
        else
            error_exit "Could not auto-detect mode. Use explicit 'export' or 'import' command."
        fi
        ;;
    export)
        if [ -z "$REPO_PATH_1" ] || [ -z "$REPO_PATH_2_OR_BRANCH_NAME" ]; then
            error_exit "Export mode requires two paths: SOURCE REPO and HOLDER REPO."
        fi
        do_export "$REPO_PATH_1" "$REPO_PATH_2_OR_BRANCH_NAME" "$N_COMMITS"
        ;;
    import)
        if [ -z "$REPO_PATH_1" ] || [ -z "$REPO_PATH_2_OR_BRANCH_NAME" ]; then
            error_exit "Import mode requires two paths: BRIDGE REPO and DEST REPO (and optionally TEMP BRANCH NAME)."
        fi
        # N_COMMITS is used as third param for branch name in import mode
        do_import "$REPO_PATH_1" "$REPO_PATH_2_OR_BRANCH_NAME" "$N_COMMITS"
        ;;
    cleanup)
        if [ -z "$REPO_PATH_1" ] || [ -z "$REPO_PATH_2_OR_BRANCH_NAME" ]; then
            error_exit "Cleanup mode requires the HOLDER REPO path and the FULL TEMP BRANCH NAME."
        fi
        do_cleanup "$REPO_PATH_1" "$REPO_PATH_2_OR_BRANCH_NAME"
        ;;
    *)
        error_exit "Invalid mode '$MODE'. Use 'export', 'import', or 'cleanup', or provide two repo paths for auto-mode."
        ;;
esac
