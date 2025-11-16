# Git Commit Bridge Bugs and Fixes

This document identifies critical bugs in `git_commit_bridge.sh` discovered during import testing and provides fixes.

## Bug #1: Patches Applied on Wrong Branch (CRITICAL)

### Location
`git_commit_bridge.sh:776` (before fix)

### The Bug
```bash
# Line 776 in do_import()
git checkout -b "$local_temp_branch" FETCH_HEAD --no-track || error_exit "Failed to checkout transfer files."
```

### What Goes Wrong
1. FETCH_HEAD points to the bridge branch (e.g., `claude/gui-profile-sync-transfer-01WqaAvCxRr6eWW2Wu33e8xP`)
2. The bridge branch only contains `.bridge-transfer/` directory with patch files
3. The bridge branch does NOT contain any source files from the project
4. When `git apply` tries to apply patches (line 894), it fails with:
   ```
   error: sources/app/(app)/new/index.tsx: No such file or directory
   error: sources/app/(app)/settings/profiles.tsx: No such file or directory
   ```

### Why It Happens
The script creates a temporary branch FROM the bridge branch's commit, not from the destination repository's current branch. This leaves the working tree with only `.bridge-transfer/` files.

### The Fix
Instead of checking out FETCH_HEAD as a branch, extract patch files to a temporary directory and stay on the destination branch:

```bash
# CURRENT (BROKEN):
git checkout -b "$local_temp_branch" FETCH_HEAD --no-track

# FIXED VERSION:
# Extract patch files from FETCH_HEAD without changing branches
local temp_patch_dir
temp_patch_dir=$(mktemp -d)
git archive FETCH_HEAD "$TRANSFER_DIR" | tar -x -C "$temp_patch_dir"

# Stay on current branch (which has all source files)
# Apply patches from temp directory
# ... apply patches ...

# Clean up temp directory
rm -rf "$temp_patch_dir"
```

## Bug #2: Commit SHAs Don't Match (IMPORTANT)

### Location
`git_commit_bridge.sh:900-911` (before fix)

### The Bug
```bash
# Lines 900-909 in do_import()
export GIT_AUTHOR_NAME="$author_name"
export GIT_AUTHOR_EMAIL="$author_email"
export GIT_AUTHOR_DATE="$date_full"
export GIT_COMMITTER_DATE="$date_full"

local full_message="$commit_subject\n\n$commit_body"

git commit -F <(echo -e "$full_message") || error_exit "..."

unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_DATE
```

### What Goes Wrong
1. Script sets `GIT_COMMITTER_DATE` but NOT `GIT_COMMITTER_NAME` or `GIT_COMMITTER_EMAIL`
2. Git uses the importing user's name/email as committer
3. Commit SHA is calculated from: tree + parent + author + committer + message
4. Different committer → Different SHA
5. Result: Imported commits have different SHAs than originals

### Example
**Source commit (Machine 1):**
```
SHA:       680705524b99f4217a4699c566fe9bc52a64709d
Author:    Andrew Hundt <ATHundt@gmail.com>
Committer: Andrew Hundt <ATHundt@gmail.com>
```

**Imported commit (Machine 2) with current script:**
```
SHA:       f2bb021081ca29cc1de78c6fa61bf7ec807de7a9  ❌ DIFFERENT!
Author:    Andrew Hundt <ATHundt@gmail.com>
Committer: Machine2User <machine2@example.com>  ❌ DIFFERENT!
```

### Why This Matters
- Breaks git history tracking across machines
- Makes it harder to verify correct import
- Prevents de-duplication of commits (git can't tell they're the same)
- Violates principle of least surprise

### The Fix
Set committer to match author for exact SHA preservation:

```bash
# CURRENT (BROKEN):
export GIT_AUTHOR_NAME="$author_name"
export GIT_AUTHOR_EMAIL="$author_email"
export GIT_AUTHOR_DATE="$date_full"
export GIT_COMMITTER_DATE="$date_full"  # Missing NAME and EMAIL!

# FIXED VERSION:
export GIT_AUTHOR_NAME="$author_name"
export GIT_AUTHOR_EMAIL="$author_email"
export GIT_AUTHOR_DATE="$date_full"
export GIT_COMMITTER_NAME="$author_name"      # ADD THIS
export GIT_COMMITTER_EMAIL="$author_email"    # ADD THIS
export GIT_COMMITTER_DATE="$date_full"
```

And update the unset:
```bash
# CURRENT (BROKEN):
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_DATE

# FIXED VERSION:
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
```

## Bug #3: Missing Committer Metadata in Export

### Location
`git_commit_bridge.sh:566-590` (export function - before fix)

### The Issue
Export only captures author metadata, not committer metadata:

```bash
# Lines 566-590 in do_export()
local parent_sha
parent_sha=$(git rev-parse "$commit_sha"^ 2>/dev/null)

# Create JSON metadata (Author info only)
cat <<EOF > "$json_file"
{
  "sha": "$commit_sha_full",
  "parent_sha": "$parent_sha",
  "author_name": "$author_name",
  "author_email": "$author_email",
  "date_full": "$date_full",
  "commit_subject": "$commit_subject",
  "commit_body": $(jq -Rs . <<< "$commit_body")
}
EOF
```

### What's Missing
No capture of:
- `committer_name`
- `committer_email`
- `committer_date`

### Why It Matters
Without committer metadata in the export, import CANNOT preserve exact SHAs even if it wanted to.

### The Fix
Add committer metadata to export:

```bash
# Get committer info
local committer_name
local committer_email
local committer_date

committer_name=$(git log -1 --pretty=format:'%cn' "$commit_sha")
committer_email=$(git log -1 --pretty=format:'%ce' "$commit_sha")
committer_date=$(git log -1 --pretty=format:'%cI' "$commit_sha")

# Create JSON metadata with both author AND committer
jq -n \
    --arg sha "$commit_sha_full" \
    --arg parent_sha "$parent_sha" \
    --arg author_name "$author_name" \
    --arg author_email "$author_email" \
    --arg author_date "$date_full" \
    --arg committer_name "$committer_name" \
    --arg committer_email "$committer_email" \
    --arg committer_date "$committer_date" \
    --arg commit_subject "$commit_subject" \
    --arg commit_body "$commit_body" \
    '{...all fields...}' > "$json_file"
```

Then update import to use committer metadata if available:

```bash
# In do_import(), check if committer fields exist
local committer_name
local committer_email
local committer_date

committer_name=$(jq -r '.committer_name // .author_name' "$json_file")
committer_email=$(jq -r '.committer_email // .author_email' "$json_file")
committer_date=$(jq -r '.committer_date // .date_full' "$json_file")

# Use committer metadata
export GIT_COMMITTER_NAME="$committer_name"
export GIT_COMMITTER_EMAIL="$committer_email"
export GIT_COMMITTER_DATE="$committer_date"
```

This provides backward compatibility: if committer fields don't exist (old exports), fall back to author.

## Summary of Required Changes

### Immediate Critical Fix (Bug #1)
**File:** `git_commit_bridge.sh`
**Lines:** 765-783 (updated in fix)
**Change:** Don't checkout FETCH_HEAD as working branch; extract patches and stay on destination branch

### Important Fix (Bug #2)
**File:** `git_commit_bridge.sh`
**Lines:** 926-934, 941 (updated in fix)
**Change:** Set `GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL` in addition to `GIT_COMMITTER_DATE`

### Enhancement (Bug #3)
**File:** `git_commit_bridge.sh`
**Lines:** 596-601, 610-622 (export), 841-848 (import) (updated in fix)
**Change:** Capture and restore committer metadata in JSON

## Testing
A fixed implementation is available in `archive/apply-bridge-patches-fixed.sh` which demonstrates the correct approach.

**Test results:**
- ✅ All patches apply successfully
- ✅ All commit SHAs match exactly
- ✅ No errors about missing files
- ✅ Author and committer metadata preserved

---

**Tested on:** 2025-11-15
**Test repository:** happy (GUI repo)
**Bridge repository:** happy-cli
**Commits tested:** 3 commits (0ecaffe, 6807055, b53ef2e)

**All fixes have been applied to git_commit_bridge.sh as of commit bc28733**
