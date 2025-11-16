# Archive Directory

This directory contains reference implementations and documentation related to fixes applied to `git_commit_bridge.sh`.

## Contents

### `apply-bridge-patches-fixed.sh`
**Working reference implementation** that demonstrates the correct approach to importing patches.

This script was created during debugging when the main `git_commit_bridge.sh` import function was broken. It shows:
- How to extract patches without checking out the bridge branch
- How to preserve exact commit SHAs by setting committer metadata
- Proper error handling and validation

**Usage:**
```bash
./apply-bridge-patches-fixed.sh <patch_directory> <destination_repo>
```

**Example:**
```bash
# After extracting patches from bridge branch
./apply-bridge-patches-fixed.sh /tmp/bridge-patches ~/my-project
```

**Status:** All fixes from this script have been incorporated into `git_commit_bridge.sh` as of commit bc28733.

### `GIT_COMMIT_BRIDGE_BUGS.md`
**Detailed bug analysis** documenting three critical bugs discovered in `git_commit_bridge.sh`:

1. **Bug #1 (CRITICAL):** Import checked out bridge branch which had no source files
2. **Bug #2 (IMPORTANT):** Didn't set committer name/email, causing SHA mismatches
3. **Bug #3 (ENHANCEMENT):** Export didn't capture committer metadata

Each bug includes:
- Exact location in code
- What goes wrong
- Why it happens
- The fix (with code examples)
- Testing results

**Status:** All documented bugs have been fixed in `git_commit_bridge.sh` as of commit bc28733.

## Why This Archive Exists

These files are kept for:
1. **Reference:** Shows the working implementation that guided the fixes
2. **Documentation:** Detailed analysis of bugs and solutions
3. **Testing:** Can be used to manually test import functionality
4. **Learning:** Demonstrates proper patch application techniques

## Relationship to Main Script

The main `git_commit_bridge.sh` script has been fixed using the approaches demonstrated in this archive. Users should use the main script, not these archive files, for normal operations.

## Version History

- **2025-11-15:** Initial archive created after fixing git_commit_bridge.sh
  - Bugs discovered during real-world import testing (GUI profile commits)
  - Working reference implementation created
  - Fixes integrated into main script (commit bc28733)
