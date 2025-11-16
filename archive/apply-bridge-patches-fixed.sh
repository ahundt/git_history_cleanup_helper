#!/bin/bash
# Fixed version of git_commit_bridge.sh import logic
# This script demonstrates the correct way to apply patches that fixes the bug in git_commit_bridge.sh
#
# THE BUG IN git_commit_bridge.sh:
# Line 776: git checkout -b "$local_temp_branch" FETCH_HEAD --no-track
# This creates a temporary branch from FETCH_HEAD (the bridge branch), which only contains
# the .bridge-transfer/ directory and NO source files. When patches are applied (line 894),
# they fail because the files they need to modify don't exist.
#
# THE FIX:
# Instead of checking out FETCH_HEAD as a branch, we should:
# 1. Extract the patch files from FETCH_HEAD to a temporary directory
# 2. Stay on the destination branch (which has all the source files)
# 3. Apply patches from the temporary directory
#
# ADDITIONAL FIX:
# The original script only sets GIT_COMMITTER_DATE but not GIT_COMMITTER_NAME/EMAIL,
# causing the committer to be whoever runs the import, which changes commit SHAs.
# To preserve exact SHAs, set committer = author.

set -e

# Configuration
PATCH_DIR="${1}"  # Must be provided as argument
DEST_REPO="${2}"  # Must be provided as argument

if [ -z "$PATCH_DIR" ] || [ -z "$DEST_REPO" ]; then
    echo "Usage: $0 <patch_directory> <destination_repo>"
    echo ""
    echo "Example:"
    echo "  $0 /tmp/bridge-patches ~/source/happy"
    echo ""
    echo "This script applies git patches from a bridge transfer to a destination repository."
    exit 1
fi

if [ ! -d "$PATCH_DIR" ]; then
    echo "ERROR: Patch directory does not exist: $PATCH_DIR"
    exit 1
fi

if [ ! -d "$DEST_REPO/.git" ]; then
    echo "ERROR: Destination is not a git repository: $DEST_REPO"
    exit 1
fi

cd "$DEST_REPO"

# Verify we're on the right branch
CURRENT_BRANCH=$(git branch --show-current)
echo "Current branch: $CURRENT_BRANCH"
echo "Destination repository: $DEST_REPO"
echo "Patch directory: $PATCH_DIR"
echo ""

# Find all patch files and process them in order (sorted by numerical prefix)
PATCH_FILES=$(find "$PATCH_DIR" -maxdepth 1 -name '[0-9][0-9][0-9]_commit_*.patch' 2>/dev/null | sort)

if [ -z "$PATCH_FILES" ]; then
    echo "ERROR: No patch files found in $PATCH_DIR"
    exit 1
fi

# Count patches
NUM_PATCHES=$(echo "$PATCH_FILES" | wc -l | tr -d ' ')
echo "Found $NUM_PATCHES patch(es) to process"
echo ""

PATCH_INDEX=0

# Process each patch in order
for PATCH_FILE in $PATCH_FILES; do
    PATCH_INDEX=$((PATCH_INDEX + 1))

    # Derive JSON file from patch file
    JSON_FILE="${PATCH_FILE/.patch/.json}"

    if [ ! -f "$JSON_FILE" ]; then
        echo "ERROR: Missing metadata file: $JSON_FILE"
        exit 1
    fi

    # Extract metadata
    COMMIT_SHA=$(jq -r '.sha' "$JSON_FILE")
    SHORT_SHA="${COMMIT_SHA:0:7}"
    AUTHOR_NAME=$(jq -r '.author_name' "$JSON_FILE")
    AUTHOR_EMAIL=$(jq -r '.author_email' "$JSON_FILE")
    DATE_FULL=$(jq -r '.date_full' "$JSON_FILE")
    COMMIT_SUBJECT=$(jq -r '.commit_subject' "$JSON_FILE")
    COMMIT_BODY=$(jq -r '.commit_body' "$JSON_FILE")
    PARENT_SHA=$(jq -r '.parent_sha' "$JSON_FILE")

    echo "=========================================="
    echo "Processing patch $PATCH_INDEX of $NUM_PATCHES: $SHORT_SHA"
    echo "Subject: $COMMIT_SUBJECT"
    echo "Parent: ${PARENT_SHA:0:7}"
    echo "=========================================="

    # Check if commit already exists
    if git cat-file -e "$COMMIT_SHA" 2>/dev/null; then
        echo "✅ Commit $SHORT_SHA already exists - skipping"
        continue
    fi

    # Validate parent exists (first patch only)
    if [ "$PATCH_INDEX" = "1" ] && [ "$PARENT_SHA" != "null" ] && [ -n "$PARENT_SHA" ]; then
        if ! git cat-file -e "$PARENT_SHA" 2>/dev/null; then
            echo "❌ ERROR: Parent commit ${PARENT_SHA:0:7} not found in destination"
            echo "This means the destination branch is missing the parent commit."
            echo "You may need to reset to a different commit first."
            exit 1
        fi
    fi

    # Apply patch
    echo "Applying patch..."
    if ! git apply --check --whitespace=fix "$PATCH_FILE"; then
        echo "❌ ERROR: Patch check failed for $SHORT_SHA"
        echo "Patch file: $PATCH_FILE"
        echo ""
        echo "Files this patch tries to modify:"
        grep '^diff --git' "$PATCH_FILE" | head
        echo ""
        echo "Check if these files exist in your working tree:"
        echo "  ls -la <file-paths-from-above>"
        exit 1
    fi

    git apply --whitespace=fix "$PATCH_FILE"

    # Stage changes
    git add -A

    # CRITICAL FIX: Set committer = author to preserve exact commit SHAs
    # The original git_commit_bridge.sh only sets GIT_COMMITTER_DATE,
    # which causes committer name/email to be whoever runs the import.
    # This changes the commit SHA even if everything else matches.
    export GIT_AUTHOR_NAME="$AUTHOR_NAME"
    export GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL"
    export GIT_AUTHOR_DATE="$DATE_FULL"
    export GIT_COMMITTER_NAME="$AUTHOR_NAME"      # FIX: Set committer name
    export GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL"    # FIX: Set committer email
    export GIT_COMMITTER_DATE="$DATE_FULL"

    # Create full message
    FULL_MESSAGE="$COMMIT_SUBJECT"
    if [ "$COMMIT_BODY" != "null" ] && [ -n "$COMMIT_BODY" ]; then
        FULL_MESSAGE="$COMMIT_SUBJECT

$COMMIT_BODY"
    fi

    # Commit
    git commit -m "$FULL_MESSAGE"

    # Verify the SHA matches
    ACTUAL_SHA=$(git rev-parse HEAD)
    if [ "$ACTUAL_SHA" != "$COMMIT_SHA" ]; then
        echo "⚠️  WARNING: SHA mismatch!"
        echo "  Expected: $COMMIT_SHA"
        echo "  Actual:   $ACTUAL_SHA"
        echo ""
        echo "This usually means:"
        echo "  - Different parent commit"
        echo "  - Different file content in working tree"
        echo "  - Different commit message or metadata"
    else
        echo "✅ SHA verified: $SHORT_SHA"
    fi

    # Unset env vars
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

    echo "✅ Successfully applied patch $PATCH_INDEX"
done

echo ""
echo "=========================================="
echo "✅ ALL PATCHES APPLIED SUCCESSFULLY"
echo "=========================================="
echo ""
echo "Review commits:"
echo "  git log --oneline -5"
echo ""
echo "Verify metadata:"
echo "  git log -3 --pretty=format:'%H %an <%ae> %aI %cI %s' --reverse"
