# Git History Cleanup Helper

<!--
Copyright 2025 Andrew Hundt

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

⚠️ **DANGER: This repository contains tools for DESTRUCTIVE Git operations** ⚠️

🚨 **HIGH RISK - USE AT YOUR OWN RISK** 🚨

This shell script removes files from your Git history using [git-filter-repo](https://github.com/newren/git-filter-repo). The tool correctly implements git-filter-repo with safety checks, but the operation itself rewrites every commit in your repository. Git identifies each commit by a unique hash (like `a1b2c3d`), and when you change a commit's contents, Git generates a completely new hash. This means every commit in your repository gets a new identifier, making your modified repository incompatible with any existing copies.

**Built on git-filter-repo:** This tool is a wrapper around the excellent [git-filter-repo](https://github.com/newren/git-filter-repo) project by Elijah Newren. All the core history rewriting functionality comes from git-filter-repo - this script adds workflow automation, safety checks, and GitHub integration around it.

## 📦 Repository Contents

This repository contains three git history rewriting tools and a test suite:

1. **`cleanup_git_history.sh`** - Removes files from git history (documented below)
   - Use case: Remove secrets, large files, or unwanted data from commit history
   - Requires: git-filter-repo 2.47+, optionally GitHub CLI

2. **`commit_author_fix_git_history.sh`** - Rewrites commit author/committer attribution
   - Use case: Fix incorrect author emails/names in commits (e.g., replace AI-generated attribution with human author)
   - Requires: git-filter-repo, optionally gpg (for commit signing) and GitHub CLI (for uploading GPG keys)
   - See: [Author Rewriting Tool](#author-rewriting-tool) section below

3. **`git_commit_bridge.sh`** - Transfers commits between unrelated repositories via patch files
   - Use case: Move commits when repositories have no common history or direct push is blocked
   - Requires: jq
   - See: [Git Commit Bridge](#git-commit-bridge) section below

4. **`test_cleanup_git_history.sh`** - Test suite for cleanup_git_history.sh

**⚠️ WARNING:**
- `cleanup_git_history.sh` and `commit_author_fix_git_history.sh` rewrite git history, creating new commit hashes and breaking existing clones
- `git_commit_bridge.sh` creates new commits in destination (does not modify source history)
- Read documentation carefully before use

## 🔧 Key Features (File Removal Tool)

- 🛡️ **Safety-first design** - Defaults to dry-run mode with detailed file listings for preview
- ✅ **Built-in verification** - Confirms file removal after cleanup operations
- 🧪 **Comprehensive testing** - Includes pattern matching, safety validation, and cross-platform support
- 📝 **Enhanced validation** - Validates paths files and provides clear error messages
- 🎯 **Pattern support** - Supports git-filter-repo path patterns including simple wildcards

## ⚠️ Critical Warnings

- 💥 **REWRITES EVERY COMMIT** - Git creates new commit hashes (like changing `a1b2c3d` to `x9y8z7w`) for every commit in your repository
- 🔥 **BREAKS YOUR COWORKERS' COPIES** - When they run `git pull`, Git will say "fatal: refusing to merge unrelated histories" because their commits no longer exist
- 💔 **DESTROYS ALL PULL REQUESTS** - PRs reference specific commit hashes that no longer exist, causing GitHub to show "This branch has conflicts that must be resolved"
- 🍴 **BREAKS ALL FORKS** - Forked repositories contain the old commit hashes and cannot sync with your rewritten repository
- 🎯 **REQUIRES FORCE PUSH** - You must run `git push --force` to overwrite GitHub's copy, which is irreversible
- 📋 **DEPENDS ON YOUR FILE LIST** - The tool correctly removes what you specify, but cannot prevent you from accidentally removing needed files

## 🎯 What It Does

Creates new versions of every commit in your repository where the specified files never existed. Git generates new commit hashes for these modified commits, breaking compatibility with all existing copies of your repository.

**⚠️ YOU ARE RESPONSIBLE FOR ALL CONSEQUENCES ⚠️**

## ⚡ Quick Start (For the Impatient)

```bash
# 1. Tell it what to delete
echo "secrets.txt" > kill-list.txt
echo "huge-file.zip" >> kill-list.txt
echo "test-data/" >> kill-list.txt

# 2. Run the script - it will check dependencies and guide you
./cleanup_git_history.sh . --permanently-remove-paths-from-file kill-list.txt --dry-run
```

**What happens when you run it:**
- 🔍 **Dependency check**: Script checks if git-filter-repo is installed, shows install instructions if missing
- 🤖 **GitHub CLI detection**: Checks for GitHub CLI and authentication, shows benefits and install info if not found  
- 👀 **Dry-run preview**: Shows exactly what would be removed with detailed file listings (script defaults to dry-run for safety!)
- ✅ **Paths file validation**: Verifies your paths file format and patterns before any operations
- 🚀 **Ready to go**: If everything looks good, remove `--dry-run` and run again

**If the script says git-filter-repo is missing:**
```bash
# macOS
brew install git-filter-repo

# Linux (Ubuntu/Debian)
sudo apt install git-filter-repo
# or
pip3 install git-filter-repo

# Linux (RHEL/CentOS/Fedora)
sudo dnf install git-filter-repo
# or
pip3 install git-filter-repo

# Windows (via pip)
pip install git-filter-repo

# Then try the script again
```

**For GitHub integration (optional but recommended):**
```bash
# macOS
brew install gh && gh auth login

# Linux (Ubuntu/Debian)
sudo apt install gh && gh auth login

# Linux (RHEL/CentOS/Fedora)
sudo dnf install gh && gh auth login

# Windows (via winget)
winget install GitHub.cli && gh auth login

# Alternative: Download from https://cli.github.com/
# Then re-run the script for GitHub branch protection and PR detection
```

## 🛡️ What Prevents Technical Failures

- 💾 **Complete repository backup** created automatically (`repo.backup-YYYYMMDD-HHMMSS`) prevents total data loss if git-filter-repo fails
- 🤖 **GitHub integration** (requires GitHub CLI):
  - Detects protected branches that would make your force-push fail with an error
  - Lists open PRs that will become unmergeable (but cannot prevent this disruption)
  - Uses GitHub API to temporarily disable "Restrict pushes that create files" and "Do not allow bypassing" settings, runs your force-push, then re-enables the same settings  
- 🔍 **Dry-run preview** shows exactly which files would be removed
  - Lists every file that matches your patterns before making changes
  - Validates paths file format to catch syntax errors
  - Defaults to dry-run mode (you must explicitly confirm to make actual changes)
- 🛑 **Confirmation prompts** require typing exact phrases like "I ACCEPT RESPONSIBILITY" to prevent accidental execution
- 📝 **Complete operation log** saved to `repo.cleanup-log-YYYYMMDD-HHMMSS.log` (next to backup, or specify with `--log-file`) records every action for debugging
- ⏸️ **Interrupt protection** prevents repository corruption if you press Ctrl+C during git-filter-repo execution
- 📋 **Team notification guidance** generates specific `git clone` commands and sample email text explaining why coworkers must delete and re-clone
- ✅ **Post-operation verification** confirms the specified files were actually removed from history

**Technical reality: This tool implements git-filter-repo correctly with multiple safety checks, but the underlying operation creates new commit hashes for every commit, requiring everyone to delete their local copies and re-clone.**

## What Gets Removed

🎯 **This script removes ONLY the files you specify in your paths file**

The script requires a `--permanently-remove-paths-from-file` argument that specifies exactly which files and directories to remove from your Git history. **No files are removed by default** - you must explicitly provide the list.

## 📦 Requirements

- **Git repository** (run from repository root)
- **[git-filter-repo](https://github.com/newren/git-filter-repo)** 2.47+ (script will check and guide installation)
- **[GitHub CLI](https://cli.github.com)** (optional, for automatic GitHub integration)

*The script checks dependencies and shows install instructions if anything is missing.*

## 🔧 Command Reference

| Option | Description |
|--------|-------------|
| `--permanently-remove-paths-from-file FILE` | **REQUIRED** - Your kill list |
| `--dry-run` | Preview mode - shows what would happen |
| `--log-file FILE` | Specify log file location (default: `repo.cleanup-log-YYYYMMDD-HHMMSS.log`) |
| `-h, --help` | Shows help and examples |

## 🔄 How It Works

### The Process

1. **Safety Checks**: Validates repository state, checks for uncommitted changes
2. **GitHub Integration**: Detects pull requests and branch protection rules
3. **Backup Creation**: Creates complete repository backup before any changes
4. **File Removal**: Uses git-filter-repo to rewrite entire history
5. **Verification**: Confirms successful removal and repository integrity
6. **Push Assistance**: Guides you through force-pushing changes to GitHub

### What Happens to Your Repository

**Before:**
- Your repository has commits with hashes like `a1b2c3d`, `e4f5g6h`, etc.
- Coworkers' local copies have these same commit hashes
- Pull requests reference these specific commit hashes
- Forks contain copies of these same commits

**After:**
- Every commit gets a new hash like `x9y8z7w`, `m3n4o5p`, etc.
- The old commit hashes (`a1b2c3d`, `e4f5g6h`) no longer exist anywhere
- Coworkers' `git pull` fails with "refusing to merge unrelated histories"
- All pull requests show as unmergeable because they reference non-existent commits
- Forks cannot sync because they contain commits that no longer exist in your repository
- The file contents (except removed files) remain identical, but Git treats this as a completely different repository

## 🚨 Important Stuff to Know

### 🔐 Security Warning

GitHub states: *"You should consider any data committed to Git to be compromised."*

**If your files contained passwords, API keys, or secrets:**
1. 🔑 **Assume they were stolen** - Anyone who cloned your repository before you ran this script has a permanent copy of your secrets
2. 🗝️ **Change credentials immediately** - Generate new passwords, revoke old API keys, create new tokens
3. 📊 **Check for unauthorized access** - Review server logs, API usage logs, and account activity for signs of misuse
4. ⚠️ **Monitor ongoing** - Compromised credentials may be used weeks or months later

⚠️ **This script only prevents future downloads** - It cannot remove copies that people already downloaded or cached copies on GitHub's servers.

### 💔 Impact on Collaboration

- 👥 **All collaborators must start over** - Their `git pull` will fail with "fatal: refusing to merge unrelated histories" because their local commits no longer exist on the remote
- 🔀 **All pull requests break** - GitHub will show "This branch has conflicts that must be resolved" because the PR references commit hashes that no longer exist  
- 🍴 **All forks become orphaned** - Forked repositories cannot sync because they contain the old commit hashes that were deleted from your repository
- 💪 **Force-push overwrites GitHub** - Running `git push --force` permanently replaces GitHub's copy with your rewritten commits

### 🛟 Recovery Options

- 💾 **Complete repository backup** created automatically before any changes (includes all branches, tags, and commit history)
- 📁 **Backup location**: `your-repo-name.backup-YYYYMMDD-HHMMSS` (complete Git repository in a folder next to yours)
- ⚠️ **Only way to undo** if you remove the wrong files or the process fails
- 🕐 **Keep backup until verified** - Test that your rewritten repository works correctly before deleting the backup
- 🚨 **No GitHub recovery** - Once you force-push, GitHub's copy is permanently overwritten

#### 🔄 How to Restore from Backup
```bash
# If something goes wrong, restore like this:
cd ..
rm -rf your-repository-name
cp -a your-repository-name.backup-YYYYMMDD-HHMMSS your-repository-name
cd your-repository-name
```


## 📋 Paths File Format and Examples

The paths file tells the script exactly which files and directories to permanently remove from your Git history.

### Format Rules
- **One path per line** in [git-filter-repo format](https://github.com/newren/git-filter-repo/blob/main/Documentation/git-filter-repo.txt)
- **Directories end with `/`** (e.g., `test_dir/`)
- **Files without trailing slash** (e.g., `unwanted.txt`)
- **Glob patterns**: Use `glob:` prefix for wildcard matching (e.g., `glob:*.log`, `glob:**/cache/**`)
- **Regex patterns**: Use `regex:` prefix for regular expression matching (e.g., `regex:.*\.tmp$`)
- **Default behavior**: Lines without prefixes are treated as literal paths
- **Comments start with `#`**
- **Empty lines ignored**

**📖 For complete pattern syntax, see [git-filter-repo documentation](https://github.com/newren/git-filter-repo/blob/main/Documentation/git-filter-repo.txt)**

### 📄 Sample Paths File (`paths-to-remove.txt`)

```
# Sample paths file for removing test and demo content
# Lines starting with # are comments and will be ignored

# Remove test directories (note the trailing slash)
test_output/
test_results/
tests/temp/
integration_tests/logs/

# Remove demo directories
demo_project/
examples/old_demos/

# Remove specific test files
test_config.json
debug_output.txt
benchmark_results.xml

# Remove all log files (glob pattern matching)
glob:*.log
glob:*.tmp

# Remove backup files (glob patterns)
glob:*.bak
glob:*.orig
glob:*~

# Remove OS-specific files
.DS_Store
Thumbs.db

# Remove IDE files
.vscode/settings.json
.idea/workspace.xml

# Remove large media files that shouldn't be in Git
demo_video.mp4
presentation.pptx
large_dataset.csv

# Remove credential files (if accidentally committed)
.env
secrets.json
api_keys.txt

# Remove build artifacts
dist/
build/
glob:*.pyc
__pycache__/
node_modules/

# Remove temporary development files
scratch.py
todo.md
notes.txt

# Complex glob patterns (requires glob: prefix)
glob:src/*/temp/
glob:**/cache/**

# Regex patterns (requires regex: prefix)
regex:.*\\.tmp$
regex:^.*/[0-9]{4}-[0-9]{2}-[0-9]{2}\\.log$
```

### 🎯 Tips for Creating Your Paths File

1. **Always start with `--dry-run`** to preview what will be removed
2. **Be specific** - avoid overly broad patterns that might remove needed files  
3. **Use `glob:` prefix** for wildcard patterns (e.g., `glob:*.log` for all .log files)
4. **Check for dependencies** - removed files might break builds or functionality
5. **Understand scope** - patterns affect entire repository history
6. **Test on a copy** of your repository first if possible


## Error Handling

### Common Issues and Solutions

**"git-filter-repo not found"**
- The script will show install instructions when you run it
- Follow the commands it provides, then try again

**"Branch protection blocks push"**
- Script uses GitHub CLI to temporarily disable specific protection rules, force-push, then restore them
- Manual alternative: Settings → Branches → Edit rules → Allow force pushes

**"Uncommitted changes detected"**
```bash
# Commit your changes first
git add .
git commit -m "Save work before cleanup"
```

**"Another instance running"**
- Wait for other instance to complete
- Or remove stale lock file if process died

### Recovery from Backup

If something goes wrong, the backup is your lifeline:
```bash
# Example: restoring my-project from backup created at 2:30 PM on Jan 15, 2025
cd ..
rm -rf my-project
cp -a my-project.backup-20250115-143000 my-project
cd my-project

# Verify the restore worked
git status
git log --oneline -5
```

**Backup Location Pattern:** `{repository-name}.backup-{YYYYMMDD}-{HHMMSS}`

## 🔄 After Running the Script

1. **Follow the interactive prompts** (accept responsibility, review files, confirm)
2. **Note the backup and log locations** 
   - Backup: `your-repo-name.backup-YYYYMMDD-HHMMSS`
   - Log: `your-repo-name.cleanup-log-YYYYMMDD-HHMMSS.log` 
3. **Force-push to GitHub** (script guides you through this)
4. **Notify your team** (everyone needs to re-clone)
5. **Contact GitHub Support** for complete removal:
   - Visit: [support.github.com/contact](https://support.github.com/contact)
   - Select: "Removing sensitive data" category
   - Provide: Repository URL, list of removed files, and confirmation that you've already removed them from history
   - GitHub will purge cached copies from their servers (this can take time)

## Best Practices

### 1. Before Running
1. [ ] **Verify git-filter-repo version 2.47 or later** (script requires this version)
2. [ ] Notify all collaborators
3. [ ] Merge or save important pull requests
4. [ ] Commit all pending work
5. [ ] Verify you're on the correct repository
6. [ ] Have recovery plan ready

### 2. After Running
1. [ ] Verify cleanup was successful
2. [ ] Test repository functionality
3. [ ] Notify team to re-clone
4. [ ] Close affected pull requests
5. [ ] Contact GitHub Support (provide repo URL, file list, confirm removal completed)
6. [ ] Keep backup until verified

### 3. Security (If Credentials Were Exposed)
1. [ ] Rotate any exposed credentials immediately
2. [ ] Review access logs for unauthorized use
3. [ ] Consider all exposed data compromised
4. [ ] Update security documentation

## 🔧 When Things Break

### Script Won't Start
1. Check you're in a Git repository
2. Verify git-filter-repo is installed
3. Ensure no uncommitted changes
4. Check another instance isn't running

### Push Fails
1. Verify GitHub authentication: `gh auth status`
2. Check branch protection settings
3. Ensure sufficient permissions
4. Try: `gh auth refresh`

### GitHub CLI Issues
1. **Install GitHub CLI:**
   - macOS: `brew install gh`
   - Linux (Ubuntu/Debian): `sudo apt install gh`
   - Linux (RHEL/CentOS/Fedora): `sudo dnf install gh`
   - Windows: `winget install GitHub.cli`
   - All platforms: Download from [cli.github.com](https://cli.github.com)
2. Authenticate: `gh auth login`
3. Verify: `gh repo view`

## Testing

A test suite is included to help verify the tool works correctly:

```bash
# Run all tests
./test_cleanup_git_history.sh

# Keep test directories for inspection
./test_cleanup_git_history.sh --no-cleanup

# Show detailed output
./test_cleanup_git_history.sh --verbose
```

The test script includes:
- **Dry-run safety testing** - Verifies no changes are made in dry-run mode
- **Basic file removal** - Tests simple path-based removal
- **Glob pattern testing** - Tests both simple and `glob:` prefix patterns
- **Custom log file handling** - Tests user-specified log file locations
- **Error handling validation** - Tests missing files and invalid paths
- **Built-in verification** - Tests post-cleanup file removal confirmation
- **Backup and log creation** - Verifies proper backup and logging functionality
- **Cross-platform compatibility** - Tests on different operating systems
- **Safety validation** - Ensures no destructive operations during testing

## Author Rewriting Tool

**Script:** `commit_author_fix_git_history.sh`

### What It Does

Rewrites author and committer fields in commits matching a specified email address. Author is who wrote the changes, committer is who applied them to the repository.

**Example use case:** Replace `old-computer <old-computer@example.com>` with `Your Name <you@example.com>` in commits matching that email.

**⚠️ Critical warnings:**
- Creates new commit hashes for ALL commits (like changing `a1b2c3d` to `x9y8z7w`)
- Breaks existing clones - collaborators must delete and re-clone
- Destroys open pull requests (PRs reference old commit hashes that no longer exist)
- Requires `git push --force` if repository was already pushed to remote
- Backup tag is the ONLY way to undo - test in a copy first if unsure

### How It Works

Uses git-filter-repo's Python callback to rewrite commit metadata:
1. Creates a backup tag before making changes
2. Runs git-filter-repo with a Python script that updates author/committer fields
3. Prompts for confirmation before rewriting and before pushing
4. Optionally sets up GPG commit signing for future commits

**⚠️ Critical:** git-filter-repo removes the origin remote as a safety measure. The script re-adds it, but you must manually restore branch tracking with `git branch --set-upstream-to=origin/main main`.

### Usage

```bash
# Basic usage - rewrite author attribution
./commit_author_fix_git_history.sh \
  --name "Your Name" \
  --email "your@email.com" \
  --old-email "old@email.com"

# With GPG signing setup
./commit_author_fix_git_history.sh \
  --name "Your Name" \
  --email "your@email.com" \
  --old-email "old@email.com" \
  --setup-signing

# Non-interactive mode (skips confirmation prompts)
./commit_author_fix_git_history.sh \
  --name "Your Name" \
  --email "your@email.com" \
  --old-email "old@email.com" \
  --non-interactive
```

### Requirements

- **Required:** git-filter-repo
- **Optional:** gpg (for commit signing), GitHub CLI (for uploading GPG keys to GitHub)

### Safety Features

- Creates backup tag before rewriting (e.g., `backup-20251115-180319`)
- Requires typing "REWRITE" to confirm history rewrite
- Requires typing "PUSH" to confirm force-push to remote
- Validates email format before processing
- Restores from backup tag if git-filter-repo fails

### Known Issues

1. **Branch tracking lost:** After running, `git push` won't work until you restore tracking with:
   ```bash
   git branch --set-upstream-to=origin/main main
   ```

2. **Special characters in names:** Names containing single quotes (e.g., `O'Brien`) cause Python syntax errors.

### When to Use This Tool

**Use when:**
- Fixing incorrect attribution (e.g., placeholder/AI emails in commit history)
- Claiming proper credit for your contributions
- Repository hasn't been pushed yet (simpler workflow)

**Don't use if:**
- Repository is actively used by multiple developers (coordinate first)
- Open pull requests exist that you need to preserve
- Unsure about which commits to change (test in a repository copy first)

**📖 For implementation details, read the script code directly.** The Python callback is at lines 224-239 in `commit_author_fix_git_history.sh`.

---

## Git Commit Bridge

**Script:** `git_commit_bridge.sh`

### What It Does

Transfers commits between machines when only one repository can push/pull to the server.

**Example:**
- **Machine 1**: my-project repo (CANNOT push to server) has new commits
- **Carrier**: carrier-repo (CAN push/pull) - different project, just carries patches
- **Machine 2**: my-project repo (CAN push to server) needs those commits

**Workflow:**
1. **Export (Machine 1)**: my-project → carrier-repo as .patch files
2. **Push**: Push carrier-repo to server
3. **Import (Machine 2)**: Pull carrier-repo → import patches to my-project
4. **Push**: Push my-project to project server

**Key:** carrier-repo is different project from my-project. Both my-project repos (Machine 1 & 2) are the same project at possibly different points in history.

### Modes

1. **EXPORT (Machine A):** Generate patch files from dev repo's last N commits, commit to bridge repo
2. **IMPORT (Machine B):** Fetch patches from bridge repo, apply to dev repo
3. **CLEANUP:** Delete temporary bridge branch after successful import

### Usage

```bash
# AUTO MODE - Automatically detects export vs import based on repo state
# Export: First arg is dev repo (has commits), second is bridge repo
./git_commit_bridge.sh ~/my-dev-repo ~/bridge-repo

# Import: First arg is bridge repo (has patches), second is dev repo
./git_commit_bridge.sh ~/bridge-repo ~/my-dev-repo

# MANUAL MODE - Explicit control
# Export last 3 commits from dev repo to bridge repo
./git_commit_bridge.sh export ~/my-dev-repo ~/bridge-repo 3

# Import from bridge repo to dev repo (specify branch if multiple exist)
./git_commit_bridge.sh import ~/bridge-repo ~/my-dev-repo claude/main-01WqaAvCxRr6eWW2Wu33e8xP

# Cleanup temporary branch from bridge repo
./git_commit_bridge.sh cleanup ~/bridge-repo claude/main-01WqaAvCxRr6eWW2Wu33e8xP

# With automatic stashing (use with caution)
./git_commit_bridge.sh ~/my-dev-repo ~/bridge-repo --stash
```

### Requirements

- **jq** - required for parsing commit metadata
- Write access to bridge repository
- **Both dev repos must be the same project on different machines** - patches apply on top of shared commit history to bring repos to parity (parent commit of first patch must exist in destination)

### How It Works

**Export process:**
1. Generates `.patch` files (binary-safe) for each commit using `git show`
2. Creates `.json` metadata files with author, committer, dates, and message
3. Files are numbered chronologically (001, 002, 003...)
4. Commits all files to a unique temporary branch in bridge repository
5. You manually push the branch: `git push origin <branch-name>`

**Import process:**
1. Fetches the bridge branch
2. Extracts `.bridge-transfer/` directory to temporary location (stays on destination branch)
3. Sorts patches by numerical prefix
4. Applies patches sequentially with `git apply`
5. Re-commits with original author/committer/date metadata preserved
6. Removes temporary patch directory

**File format:**
- Patches: `001_commit_abc1234.patch`, `002_commit_def5678.patch`
- Metadata: `001_commit_abc1234.json`, `002_commit_def5678.json`
- Stored in: `.bridge-transfer/` directory

### Safety Features

- **Auto-stashing:** Optional `--stash` flag to handle uncommitted changes (disabled by default)
- **Unique branch names:** Uses random suffix to prevent conflicts (`claude/main-01WqaAvCxRr6eWW2Wu33e8xP`)
- **Metadata preservation:** Maintains exact author, date, and commit message
- **Orphaned stash detection:** Warns about leftover stashes from previous failed runs
- **Error recovery guidance:** Provides exact commands to restore stashed changes if script fails

### Limitations

- Does not transfer git tags or references
- Requires manual push after export
- Cannot handle merge commits (linearizes history)
- Bridge repository must have a remote configured
- **Preserves exact commit SHAs** when author = committer (most common case)
- Full author and committer metadata preserved from source
- Patch conflicts fail import if destination has conflicting changes
- GPG signatures not preserved

### Security Note

Bridge repository temporarily contains your commit messages and code changes. Use a private repository or delete the bridge branch after import completes.

### When to Use This Tool

**Use when:**
- Only one repository can push/pull to server (e.g., restricted development environment)
- Developing same project on multiple machines that need to stay in sync
- Network/environment restrictions prevent direct push between dev repos
- You need to review commits before applying them (inspect .patch files)

**Don't use if:**
- All repositories have direct push/pull access (use normal `git push` instead)
- Trying to transfer between completely different projects (repos must share commit history)
- Merge commits must be preserved (this linearizes history)

**Important Notes:**
- **SHA Preservation:** Exact commit SHAs are preserved when author = committer (typical case)
- **Metadata Fidelity:** Full author and committer information transferred via JSON metadata
- **Parent Validation:** Parent commit of first patch must exist in destination repository
- **Backward Compatible:** Import works with both old exports (author only) and new exports (author + committer)

**📖 For implementation details, read the script code directly.** Core transfer logic is in the `do_export()` and `do_import()` functions in `git_commit_bridge.sh`.

---

## Documentation and References

- **GitHub Official Guide**: [Removing sensitive data from a repository](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)
- **git-filter-repo Documentation**: [github.com/newren/git-filter-repo](https://github.com/newren/git-filter-repo)
- **GitHub CLI**: [cli.github.com](https://cli.github.com)
- **GitHub Support**: [support.github.com/contact](https://support.github.com/contact)
- **Homebrew**: [brew.sh](https://brew.sh) (for macOS installations)

## ⚖️ License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) file for details.

**Author:** Andrew Hundt ([@ahundt](https://github.com/ahundt))

---

🚨 **FINAL WARNING: This operation is permanent and can destroy your repository. You assume all risks. Always create backups and notify your team before proceeding.** 🚨