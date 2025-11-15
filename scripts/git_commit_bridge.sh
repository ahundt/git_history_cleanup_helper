#!/bin/bash

# ==============================================================================
# Git Commit Bridge Script (Patch File Transfer)
# Purpose: Robustly transfers COMMITTED changes from an incompatible source
#          repository (REPO_SRC) to a remote via an intermediary repository (REPO_HOLDER).
#          Changes are moved as a sequence of uniquely named .patch files and metadata
#          as .json files, preserving transfer order.
#
# Modes:
# 1. EXPORT: Generates ordered patch/metadata files for the last N commits,
#    commits these files to a unique temporary branch, and pushes that branch
#    to the remote via REPO_HOLDER.
# 2. IMPORT: Fetches the branch, sorts the patches by the chronological index
#    prefix, applies them sequentially, and re-commits with preserved metadata.
# 3. CLEANUP: Deletes the temporary branch both locally and remotely from REPO_HOLDER.
# ==============================================================================

# --- Configuration ---
RANDOM_SUFFIX="01WqaAvCxRr6eWW2Wu33e8xP"
TEMP_BRANCH_BASE="claude"
TRANSFER_DIR=".bridge-transfer" # Dedicated directory inside REPO 1 root for transfer files
TRANSFER_FILE_PREFIX="commit"
# --- End Configuration ---

# Function to display error message and exit
error_exit() {
    echo -e "\n======================================================="
    echo -e "!!! ERROR: $1" >&2
    echo -e "======================================================="
    exit 1
}

# Function to check for required utility (jq)
check_dependencies() {
    command -v jq >/dev/null 2>&1 || error_exit "Required dependency 'jq' not found. Please install 'jq' (JSON processor) to handle metadata."
}

# Function to check for uncommitted changes
# The EXPORT source (REPO 2) MUST be clean, as the transfer starts from a commit.
check_clean_working_directory() {
    local repo_path="$1"
    local repo_name=$(basename "$repo_path")

    cd "$repo_path" || error_exit "Could not change directory to $repo_path. Please check the path."

    if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        error_exit "Path '$repo_path' is not a valid Git repository."
    fi

    # Check for uncommitted work
    if [[ -n $(git status --porcelain) ]]; then
        error_exit "Repository '$repo_name' has uncommitted changes. Please commit or stash them before running this script."
    fi
}

# Function to get the current branch name
get_current_branch() {
    git rev-parse --abbrev-ref HEAD
}

# Function to count unpushed commits (for auto-mode)
get_unpushed_commit_count() {
    local repo_path="$1"
    cd "$repo_path"

    local current_branch=$(get_current_branch)
    local upstream_branch=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)

    if [ -z "$upstream_branch" ]; then
        echo "0"
        return 1
    fi

    local count=$(git rev-list --count $upstream_branch..HEAD 2>/dev/null || echo "0")
    echo "$count"
    return 0
}

# Function to find bridge branches (for auto-mode)
find_bridge_branches() {
    local repo_path="$1"
    cd "$repo_path"

    git fetch origin --quiet 2>/dev/null || true
    git branch -r | grep "origin/${TEMP_BRANCH_BASE}/" | sed 's/.*origin\///' | grep "${RANDOM_SUFFIX}$" || true
}

# Function to auto-detect operation mode
auto_detect_mode() {
    local repo1_path="$1"
    local repo2_path="$2"

    # Check if REPO1 has bridge branches (indicates IMPORT scenario)
    cd "$repo1_path"
    local bridge_branches=$(find_bridge_branches "$repo1_path")

    if [ -n "$bridge_branches" ]; then
        echo "IMPORT"
        return 0
    fi

    # Check if REPO1 has unpushed commits (indicates EXPORT scenario)
    local unpushed=$(get_unpushed_commit_count "$repo1_path")
    if [ "$unpushed" -gt 0 ]; then
        echo "EXPORT"
        return 0
    fi

    # Check if REPO1 has commits (even without upstream)
    cd "$repo1_path"
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
    check_clean_working_directory "$repo2_src_path"
    local repo2_original_branch=$(get_current_branch)

    # Check REPO 1 (The PUSHING/HOLDER repository)
    check_clean_working_directory "$repo1_holder_path"
    local repo1_original_branch=$(get_current_branch)

    echo "INFO: REPO 2 Source path: $repo2_src_path (Branch: $repo2_original_branch)"
    echo "INFO: REPO 1 Holder path: $repo1_holder_path (Branch: $repo1_original_branch)"

    cd "$repo2_src_path"
    local head_commit=$(git rev-parse HEAD)

    if [ -z "$head_commit" ]; then
        error_exit "REPO 2 ($repo2_src_path) has no commits. Cannot export."
    fi

    # Construct the unique, safe temporary branch name
    local temp_branch="${TEMP_BRANCH_BASE}/${repo2_original_branch}-${RANDOM_SUFFIX}"
    echo "INFO: Using temporary branch name: ${temp_branch}"

    # Create a temporary working directory for file generation
    local temp_work_dir="/tmp/git_bridge_export_$$"
    mkdir -p "$temp_work_dir/$TRANSFER_DIR" || error_exit "Failed to create temporary directory for patch generation."

    # --- Core Transfer Logic ---

    echo -e "\n1. Generating $num_commits ordered patch and metadata files..."

    # Get the list of the last N commit SHAs, OLDEST FIRST (--reverse)
    local commit_list=($(git rev-list --max-count=$num_commits --abbrev-commit --reverse HEAD))
    local total_generated=0
    local commit_index=1 # Start index at 1 for chronological ordering

    for commit_sha in "${commit_list[@]}"; do
        local short_sha=$(echo "$commit_sha" | cut -c 1-7)
        local parent_sha=$(git rev-parse "$commit_sha"^ 2>/dev/null)
        local index_str=$(printf "%03d" $commit_index) # Zero-padded index (001, 002, ...)

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
        local commit_sha_full=$(git log -1 --pretty=format:'%H' "$commit_sha")
        local author_name=$(git log -1 --pretty=format:'%an' "$commit_sha")
        local author_email=$(git log -1 --pretty=format:'%ae' "$commit_sha")
        local date_full=$(git log -1 --pretty=format:'%aI' "$commit_sha")
        local commit_subject=$(git log -1 --pretty=format:'%s' "$commit_sha")
        local commit_body=$(git log -1 --pretty=format:'%b' "$commit_sha")

        # Use jq to properly encode all values as JSON (handles special characters and escaping)
        jq -n \
            --arg sha "$commit_sha_full" \
            --arg author_name "$author_name" \
            --arg author_email "$author_email" \
            --arg date_full "$date_full" \
            --arg commit_subject "$commit_subject" \
            --arg commit_body "$commit_body" \
            '{sha: $sha, author_name: $author_name, author_email: $author_email, date_full: $date_full, commit_subject: $commit_subject, commit_body: $commit_body}' \
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
    cd "$repo1_holder_path"

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
    local bridge_commit=$(git rev-parse HEAD)

    # 3. Return to original branch and clean up temp work directory
    echo -e "\n3. Cleaning up local workspace in REPO 1 Holder..."
    git checkout "$repo1_original_branch" || error_exit "Failed to return to original branch in REPO 1. Manual intervention needed."
    rm -rf "$temp_work_dir"

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
        local bridge_branches=$(find_bridge_branches "$repo1_bridge_path")

        if [ -z "$bridge_branches" ]; then
            error_exit "No bridge branches found. Please provide branch name manually."
        fi

        local branch_count=$(echo "$bridge_branches" | wc -l)

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

    # Check REPO 2 (The DESTINATION repository)
    check_clean_working_directory "$repo2_dest_path"
    local repo2_original_branch=$(get_current_branch)

    echo "INFO: Bridge path: $repo1_bridge_path"
    echo "INFO: Destination path: $repo2_dest_path (Branch: $repo2_original_branch)"

    cd "$repo2_dest_path"

    # 1. Fetch the bridge branch from the bridge repository
    echo -e "\n1. Fetching temporary branch '$temp_branch' from bridge repository..."
    git fetch "$repo1_bridge_path" "$temp_branch" || error_exit "Failed to fetch branch '$temp_branch' from bridge repo. Check repo path and branch name."

    # 2. Check out the transfer files into a temporary local branch
    local local_temp_branch="local-bridge-$$"
    echo "2. Creating local branch '$local_temp_branch' to stage files..."
    git checkout -b "$local_temp_branch" FETCH_HEAD --no-track || error_exit "Failed to checkout transfer files."

    if [ ! -d "$TRANSFER_DIR" ]; then
        error_exit "Transfer directory '$TRANSFER_DIR' not found in the fetched branch."
    fi

    # 3. Sort patches by filename (which contains the chronological index) and apply sequentially
    echo -e "\n3. Sorting and applying patches sequentially..."

    # The 'ls ... | sort' command relies on the 001_, 002_ prefix for correct ordering
    local patch_files_sorted=$(ls -1 "$TRANSFER_DIR/"[0-9][0-9][0-9]_"${TRANSFER_FILE_PREFIX}_"*.patch 2>/dev/null | sort)
    local num_patches=0
    local applied_count=0

    # Count the number of patches found
    for file in $patch_files_sorted; do
        num_patches=$((num_patches + 1))
    done

    if [ "$num_patches" -eq 0 ]; then
        error_exit "No patch files found in the transfer directory."
    fi

    # Iterate over the correctly sorted file list
    for patch_file in $patch_files_sorted; do
        # Extract the SHA from the file name using sed's extended regex for reliability
        # Matches: 001_commit_SHA.patch and captures SHA
        local filename=$(basename "$patch_file")
        local short_sha=$(echo "$filename" | sed -E "s/^[0-9]+_${TRANSFER_FILE_PREFIX}_([0-9a-fA-F]+)\.patch$/\1/")

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

        # Apply the patch
        git apply --check --whitespace=fix "$patch_file" || error_exit "Patch check failed for $short_sha. Resolve conflicts manually, then run 'git checkout -- $TRANSFER_DIR' to remove transfer files."
        git apply --whitespace=fix "$patch_file" || error_exit "Failed to apply patch for $short_sha. Manual conflict resolution needed."

        # Extract Metadata
        local author_name=$(jq -r '.author_name' "$json_file")
        local author_email=$(jq -r '.author_email' "$json_file")
        local commit_subject=$(jq -r '.commit_subject' "$json_file")
        local commit_body=$(jq -r '.commit_body' "$json_file")

        # Prepare commit
        git add .

        # Preserve original author details (Committer will be the user on Machine 2)
        export GIT_AUTHOR_NAME="$author_name"
        export GIT_AUTHOR_EMAIL="$author_email"

        local full_message="$commit_subject\n\n$commit_body"

        git commit -F <(echo -e "$full_message") || error_exit "Failed to create final commit for $short_sha. Are there changes to commit?"


    done

    # 4. Final cleanup of transfer files and temporary branch
    echo -e "\n4. Final cleanup..."

    # Remove the transfer directory
    rm -rf "$TRANSFER_DIR" || echo "Warning: Failed to remove transfer directory locally."

    # Switch back to original branch
    git checkout "$repo2_original_branch" || error_exit "Failed to return to original branch. Manual intervention needed."

    # Delete temporary branch
    git branch -D "$local_temp_branch" || error_exit "Failed to delete temporary local branch. Manual intervention needed."

    echo -e "\n✅ IMPORT SUCCESSFUL."
    echo "$applied_count commit(s) have been applied and committed to your current branch ($repo2_original_branch) with full metadata preserved."
    echo "You can now push the current branch to the remote."
    echo "Next: Run 'cleanup' on the originating machine (REPO 1) to remove the remote branch: $temp_branch"
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

    # Check REPO 1
    cd "$repo1_holder_path" || error_exit "Could not change directory to $repo1_holder_path"

    # 1. Delete remote branch
    echo -e "\n1. Deleting remote bridge branch '$temp_branch' from origin..."
    git push origin --delete "$temp_branch" || error_exit "Failed to delete remote branch. Check REPO 1's push access."

    # 2. Delete local branch (if it exists)
    if git branch --list "$temp_branch" | grep -q "$temp_branch"; then
        echo "2. Deleting local branch '$temp_branch' from REPO 1..."
        git branch -D "$temp_branch" || echo "Warning: Failed to delete local branch (manual delete may be required)."
    else
        echo "2. Local branch '$temp_branch' not found in REPO 1 (already clean)."
    fi

    echo -e "\n✅ CLEANUP SUCCESSFUL."
    echo "The transfer bridge has been safely removed from both REPO 1 and GitHub."
}

# ==============================================================================
# Main Script Logic
# ==============================================================================

# Parse arguments - detect auto-mode vs manual mode
if [[ "$1" == "export" ]] || [[ "$1" == "import" ]] || [[ "$1" == "cleanup" ]]; then
    # Manual mode: explicit mode specified
    MODE="$1"
    REPO_PATH_1="$2"
    REPO_PATH_2_OR_BRANCH_NAME="$3"
    N_COMMITS="$4"
else
    # Auto mode: first arg is a path, detect mode automatically
    MODE="auto"
    REPO_PATH_1="$1"
    REPO_PATH_2_OR_BRANCH_NAME="$2"
    N_COMMITS="$3"
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
