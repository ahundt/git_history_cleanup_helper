#!/bin/bash
# Copyright 2025 Andrew Hundt
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Git History Cleanup Script
# Author: Andrew Hundt (@ahundt)
# Follows GitHub's official documentation for removing sensitive data
# Requires git-filter-repo version 2.47 or later
# Reference: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository

# DESIGN PRINCIPLES:
# 1. Easy to use correctly, hard to use incorrectly
#    - Requires explicit "I ACCEPT RESPONSIBILITY" to proceed
#    - Uses action-specific prompts (e.g., 'push', 'skip') not generic yes/no
#    - Defaults to safety (e.g., creates mandatory backup before any changes)
#    - Clear warnings about irreversible operations
#
# 2. Automate dangerous operations safely
#    - Automatically handles GitHub branch protection if needed
#    - Creates comprehensive logs for debugging
#    - Restores settings on exit (even on failure)
#    - Uses trap handlers to ensure cleanup
#
# 3. Explain what is happening and why
#    - Each step explains its purpose and impacts
#    - Distinguishes between local and remote effects
#    - Shows GitHub API responses for transparency
#    - Provides context for both solo developers and teams
#
# 4. Fail safely and obviously
#    - set -euo pipefail ensures script stops on errors
#    - Validates all inputs before making changes
#    - Checks prerequisites (git-filter-repo, repository status)
#    - Provides clear error messages with recovery steps
#    - Run shellcheck after any changes to verify syntax
#
# GOTCHAS AND IMPORTANT NOTES:
# - This script affects ALL branches, not just the current one
# - Ctrl+C during git-filter-repo WILL corrupt your repository
# - GitHub caches removed data for up to 90 days
# - Exposed credentials should be considered compromised immediately
# - The backup is your ONLY recovery method after filter-repo runs
# - Branch protection must be temporarily disabled for force-push
# - All existing pull requests will become unmergeable
# - Every clone of the repository must be deleted and re-cloned
#
# USAGE:
#   ./cleanup_git_history.sh [OPTIONS] [REPOSITORY_PATH]
#   ./cleanup_git_history.sh --paths-from-file custom-paths.txt /path/to/repo
#   ./cleanup_git_history.sh --dry-run  # See what would be done

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Set secure umask
umask 077

# Script constants
SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_NAME

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_error() { echo -e "${RED}ERROR: $1${NC}" >&2; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}WARNING: $1${NC}"; }
print_info() { echo -e "$1"; }
print_question() { echo -e "${BLUE}QUESTION: $1${NC}"; }

# Function to restore GitHub branch protection rules
# This restores the security settings that prevent force-pushes and accidental deletions
restore_github_branch_protection_rules() {
    if [ "${PROTECTION_MODIFIED:-false}" = true ] && [ "${GH_AVAILABLE:-false}" = true ] && [ -n "${CURRENT_PROTECTION:-}" ]; then
        echo "=== GITHUB BRANCH PROTECTION RESTORATION ATTEMPT at $(date) ==="
        echo "PROTECTION_MODIFIED=$PROTECTION_MODIFIED"
        echo "GH_AVAILABLE=$GH_AVAILABLE"
        echo "CURRENT_BRANCH=${CURRENT_BRANCH:-not set}"
        
        print_info "Restoring GitHub branch protection rules..."
        echo "This will re-enable the settings that prevent force-pushes to your branch"
        # First verify the JSON is valid
        if ! echo "$CURRENT_PROTECTION" | jq empty 2>/dev/null; then
            print_error "Saved GitHub protection settings are invalid"
            print_warning "You need to manually restore branch protection:"
            echo "  1. Go to GitHub.com and open your repository"
            echo "  2. Click Settings → Branches → Edit rules"
            echo "  3. Disable 'Allow force pushes' to protect your branch"
            echo "=== RESTORATION FAILED: Invalid saved settings ==="
            return 1
        fi
        
        # Attempt to restore with modified force push setting
        echo "Calling GitHub API to restore branch protection rules..."
        if gh api -X PUT "repos/{owner}/{repo}/branches/${CURRENT_BRANCH:-main}/protection" \
            --input - <<< "$(echo "$CURRENT_PROTECTION" | jq '.allow_force_pushes.enabled = false' 2>/dev/null)" 2>/dev/null; then
            print_success "GitHub branch protection rules restored successfully"
            echo "Your branch is now protected from force-pushes again"
            echo "=== RESTORATION SUCCESSFUL at $(date) ==="
            export PROTECTION_MODIFIED=false
            return 0
        else
            print_warning "Could not automatically restore GitHub branch protection"
            echo "IMPORTANT: Your branch is currently unprotected from force-pushes"
            echo "To restore protection manually:"
            echo "  1. Go to GitHub.com and open your repository"
            echo "  2. Click Settings → Branches → Edit rules"
            echo "  3. Disable 'Allow force pushes' to protect your branch"
            echo "Risk: Without this protection, accidental force-pushes could damage your branch"
            echo "=== RESTORATION FAILED: GitHub API error ==="
            return 1
        fi
    else
        echo "Protection restoration skipped: MODIFIED=$PROTECTION_MODIFIED GH=$GH_AVAILABLE PROTECTION_SET=$([ -n "${CURRENT_PROTECTION:-}" ] && echo "yes" || echo "no")"
    fi
    return 0
}

# Global variables for cleanup
PATHS_FILE=""
TEMP_PATHS_FILE=""  # Only set if we created a temporary file
LOCK_FILE=""
LOCK_DIR=""

# Trap to ensure cleanup on exit and interruption
cleanup() {
    local exit_code=$?
    
    # Restore branch protection if we modified it (while still logging)
    if [ "${PROTECTION_MODIFIED:-false}" = true ]; then
        echo ""
        print_warning "Restoring GitHub branch protection rules due to script exit..."
        echo "This ensures your branch remains protected even if the script was interrupted"
        restore_github_branch_protection_rules
    fi
    
    # Only remove paths file if we created it (not user-provided)
    if [ -n "${TEMP_PATHS_FILE:-}" ] && [ -f "$TEMP_PATHS_FILE" ]; then
        # Securely overwrite temporary paths file before deletion
        if command -v shred &>/dev/null; then
            shred -f "$TEMP_PATHS_FILE" 2>/dev/null || true
        else
            dd if=/dev/urandom of="$TEMP_PATHS_FILE" bs=1024 count=1 2>/dev/null || true
        fi
        rm -f "$TEMP_PATHS_FILE" 2>/dev/null || true
    fi
    if [ -n "${LOCK_FILE:-}" ] && [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE" 2>/dev/null || true
    fi
    if [ $exit_code -ne 0 ]; then
        print_error "Script interrupted or failed. Check backup at: ${BACKUP_DIR:-not created}"
        echo "Review log file for details: ${LOG_FILE:-not created}"
    fi
    
    echo "Cleanup completed at $(date)"
    
    # Restore original stdout/stderr if they were saved (do this LAST)
    if [ -n "${LOG_FILE:-}" ]; then
        # Give tee processes time to flush
        sleep 0.1
        exec 1>&3 2>&4 2>/dev/null || true
        # Now kill tee processes
        pkill -f "tee.*$LOG_FILE" 2>/dev/null || true
    fi
    
    # Final message to terminal (after stdout restored)
    if [ $exit_code -ne 0 ] && [ -n "${LOG_FILE:-}" ]; then
        echo "Script failed. Review log: $LOG_FILE" >&2
    fi
}
# Initially only trap EXIT and TERM - we'll handle INT specially
trap cleanup EXIT TERM

# Flag to track if we're in a critical section
CRITICAL_OPERATION=false

# Handler for Ctrl+C (SIGINT)
handle_interrupt() {
    if [ "$CRITICAL_OPERATION" = true ]; then
        echo "" >&2
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
        echo -e "${RED}CRITICAL OPERATION IN PROGRESS - DO NOT FORCE QUIT!${NC}" >&2
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
        echo "" >&2
        echo "Please wait for the current operation to complete." >&2
        echo "Force interruption WILL CORRUPT your repository." >&2
        echo "" >&2
        echo "If you must exit, the backup is at: ${BACKUP_DIR:-not created yet}" >&2
        echo "" >&2
        return  # Don't exit, just return from handler
    else
        echo ""
        print_info "Interrupt received. Exiting safely..."
        exit 130  # Standard exit code for SIGINT
    fi
}

# Set up interrupt handler
trap handle_interrupt INT

# Log file will be created after backup directory is determined
# (moved to after backup creation step)

# Parse command line options FIRST to handle --help before warnings
show_usage() {
    echo "⚠️  DANGER: This tool PERMANENTLY DESTROYS Git history ⚠️"
    echo "🚨 IRREVERSIBLE operation - no undo possible without backup"
    echo "💔 BREAKS all existing clones, forks, and pull requests"
    echo "🎯 YOU ASSUME ALL RISKS - can destroy your entire repository"
    echo ""
    echo "Usage: $SCRIPT_NAME REPOSITORY_PATH --permanently-remove-paths-from-file FILE [OPTIONS]"
    echo ""
    echo "Remove files from Git history using git-filter-repo"
    echo ""
    echo "Arguments:"
    echo "  REPOSITORY_PATH                           Path to git repository (REQUIRED)"
    echo ""
    echo "Required Options:"
    echo "  --permanently-remove-paths-from-file FILE   Use FILE containing paths to PERMANENTLY remove (REQUIRED)"
    echo ""
    echo "Other Options:"
    echo "  --dry-run                                 Show what would be done without making changes"
    echo "  --log-file FILE                           Specify log file location (default: next to backup)"
    echo "  -h, --help                                Show this help message"
    echo ""
    echo "⚠️  CRITICAL: ALWAYS use --dry-run first to preview changes"
    echo "📖 Read full documentation before using: README.md"
    echo ""
    echo "📁 BACKUP LOCATION:"
    echo "   {repository-name}.backup-{YYYYMMDD}-{HHMMSS}"
    echo "   (created next to your repository directory)"
    echo "   This backup is your ONLY recovery option!"
    echo ""
    echo "Paths File Format:"
    echo "  One path per line in git-filter-repo format:"
    echo "    directory_name/"
    echo "    file_name.txt"
    echo "    pattern*.log"
    echo "    # Comments start with #"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME /path/to/repo --permanently-remove-paths-from-file my-files.txt --dry-run"
    echo "  $SCRIPT_NAME /path/to/repo --permanently-remove-paths-from-file list.txt --dry-run"
    echo "  $SCRIPT_NAME . --permanently-remove-paths-from-file list.txt --dry-run"
    echo "  $SCRIPT_NAME /path/to/repo --permanently-remove-paths-from-file list.txt"
    exit 0
}

# Initialize variables
DRY_RUN=false
REPO_PATH=""
PATHS_FILE=""
USER_PROVIDED_PATHS=false

# Parse arguments EARLY to handle --help
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --permanently-remove-paths-from-file)
            if [ -z "${2:-}" ]; then
                print_error "--permanently-remove-paths-from-file requires a file path"
                exit 1
            fi
            PATHS_FILE="$2"
            USER_PROVIDED_PATHS=true
            shift 2
            ;;
        --log-file)
            if [ -z "${2:-}" ]; then
                print_error "--log-file requires a file path"
                exit 1
            fi
            USER_LOG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            ;;
        -*)
            print_error "Unknown option: $1"
            show_usage
            ;;
        *)
            # First positional argument is repository path
            if [ -z "$REPO_PATH" ]; then
                REPO_PATH="$1"
            else
                print_error "Multiple repository paths specified: '$REPO_PATH' and '$1'"
                echo "Only one repository path is allowed."
                exit 1
            fi
            shift
            ;;
    esac
done

# Check that repository path was provided
if [ -z "$REPO_PATH" ]; then
    print_error "Repository path is required!"
    echo ""
    echo "Usage: $SCRIPT_NAME REPOSITORY_PATH --permanently-remove-paths-from-file FILE [OPTIONS]"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME /path/to/repo --permanently-remove-paths-from-file my-files.txt --dry-run"
    echo "  $SCRIPT_NAME . --permanently-remove-paths-from-file my-files.txt --dry-run"
    echo ""
    echo "Run '$SCRIPT_NAME --help' for full help."
    exit 1
fi

echo "Git History Cleanup Script"
echo "=========================="
echo "Started at: $(date)"
echo ""

print_warning "DANGER: This script is DESTRUCTIVE and IRREVERSIBLE"
echo ""
echo "This script will:"
echo "  - PERMANENTLY rewrite your entire Git history"
echo "  - Break ALL existing clones and forks"
echo "  - Make recovery impossible without the backup"
echo ""
echo "BY RUNNING THIS SCRIPT, YOU ACCEPT FULL RESPONSIBILITY FOR:"
echo "  - Any data loss or corruption"
echo "  - Breaking collaborator workflows"
echo "  - Any security implications"
echo ""
echo "Based on GitHub's official documentation:"
echo "https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository"
echo ""

# Comprehensive explanation of what this script does
print_warning "CRITICAL: This script will PERMANENTLY rewrite your Git history!"
echo ""
echo "This script removes test/demo files from your Git repository's ENTIRE history."
echo ""
echo "LOCAL IMPACTS (on your computer):"
echo "  - Rewrites ALL commits in your repository history"
echo "  - Changes EVERY commit SHA (identifier) in the repository"
echo "  - Creates a full backup before making changes"
echo "  - Removes your Git remotes temporarily (re-adds them after)"
echo ""
echo "REMOTE IMPACTS (on GitHub):"
echo "  - Requires force-pushing to overwrite GitHub's history"
echo "  - Breaks ALL existing pull requests (they reference old SHAs)"
echo "  - Forces ALL team members to delete and re-clone the repository"
echo "  - May require temporarily disabling GitHub branch protection rules"
echo ""
echo "GITHUB FEATURES USED:"
echo "  - GitHub API: Checks repository settings and pull requests"
echo "  - Branch Protection: Security rules that prevent force-pushes"
echo "  - gh CLI: GitHub's command-line tool for API access"
echo ""
echo "Tool information:"
echo "  - Uses git-filter-repo (GitHub's recommended tool)"
echo "  - Documentation: https://github.com/newren/git-filter-repo"
echo ""
print_question "Do you accept FULL RESPONSIBILITY for using this dangerous script?"
echo "Type exactly: I ACCEPT RESPONSIBILITY"
echo "Or press Enter/Ctrl+C to exit"
read -rp "> " understand_confirm
if [ "$understand_confirm" != "I ACCEPT RESPONSIBILITY" ]; then
    print_info "Exiting without making changes."
    exit 0
fi
echo ""

# Argument parsing was moved earlier to handle --help before warnings

# Validate paths file if provided
if [ "$USER_PROVIDED_PATHS" = true ]; then
    if [ ! -f "$PATHS_FILE" ]; then
        print_error "Paths file not found: $PATHS_FILE"
        exit 1
    fi
    PATHS_FILE=$(realpath "$PATHS_FILE")
    print_info "Using paths from file: $PATHS_FILE"
fi

# Change to repository directory
if [ ! -d "$REPO_PATH" ]; then
    print_error "Directory not found: $REPO_PATH"
    exit 1
fi

cd "$REPO_PATH" || exit 1
REPO_PATH=$(pwd)

if [ "$DRY_RUN" = true ]; then
    print_info "DRY RUN MODE - No changes will be made"
    echo ""
fi

print_info "Working in repository: $REPO_PATH"
echo ""

# Step 1: Safety checks
print_info "Step 1: Performing safety checks..."

# Check we're in a git repository
if [ ! -d .git ]; then
    print_error "Not in a git repository. Please run from the repository root."
    exit 1
fi

# Check GitHub CLI authentication early
echo ""
echo "Checking if GitHub CLI (gh) is authenticated..."
echo "Why: This script needs to communicate with GitHub.com"
echo ""
if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null 2>&1; then
        export GH_AVAILABLE=true
        print_success "GitHub CLI is authenticated"
        echo "This enables automated features:"
        echo "  - Detecting pull requests that would break"
        echo "  - Checking if your branch has protection rules"
        echo "  - Automating protection rule changes if needed"
    else
        export GH_AVAILABLE=false
        print_warning "GitHub CLI is installed but not authenticated"
        echo "To authenticate, run: gh auth login"
        echo ""
        echo "Impact of continuing without authentication:"
        echo "  - Cannot detect pull requests automatically"
        echo "  - Cannot check branch protection settings"
        echo "  - More manual steps will be required"
        echo "Type 'continue' without automation, or 'exit' to cancel"
        read -rp "> " gh_confirm
        if [ "$(echo "$gh_confirm" | tr '[:upper:]' '[:lower:]')" != "continue" ]; then
            exit 1
        fi
    fi
else
    export GH_AVAILABLE=false
    print_info "GitHub CLI not installed"
    echo "Without it, you'll need to:"
    echo "  - Manually check for pull requests on GitHub.com"
    echo "  - Manually manage any branch protection settings"
    echo "To install: brew install gh (macOS) or see https://cli.github.com"
fi
echo ""

# Create lock file to prevent concurrent execution
# Use /var/run if available (more secure), otherwise fall back to /tmp
if [ -w /var/run ]; then
    LOCK_DIR="/var/run"
elif [ -w /var/tmp ]; then
    LOCK_DIR="/var/tmp"
else
    LOCK_DIR="/tmp"
fi

# Create lock file with secure permissions
if command -v sha256sum &>/dev/null; then
    LOCK_HASH=$(pwd | sha256sum | cut -d' ' -f1)
elif command -v shasum &>/dev/null; then
    LOCK_HASH=$(pwd | shasum -a 256 | cut -d' ' -f1)
else
    # Fallback to simple directory name encoding
    LOCK_HASH=$(pwd | tr '/' '_' | tr -cd '[:alnum:]_')
fi
LOCK_FILE="$LOCK_DIR/git-cleanup-${LOCK_HASH}.lock"
if ! (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
    # Check if the PID in the lock file is still running
    if [ -f "$LOCK_FILE" ]; then
        OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
        if [ "$OLD_PID" != "unknown" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            print_error "Another instance (PID: $OLD_PID) is already running"
        else
            # Stale lock file, remove it and retry
            rm -f "$LOCK_FILE"
            if (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
                print_warning "Removed stale lock file and continuing"
            else
                print_error "Failed to create lock file after removing stale lock"
                exit 1
            fi
        fi
    else
        print_error "Cannot create lock file: $LOCK_FILE"
        exit 1
    fi
else
    # Set secure permissions on lock file
    chmod 600 "$LOCK_FILE" 2>/dev/null || true
fi

# Check for git filter-repo and version
if ! command -v git-filter-repo &> /dev/null; then
    print_error "git-filter-repo is not installed."
    echo ""
    echo "WHY: This tool is required to safely remove files from git history."
    echo "HOW TO INSTALL:"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "  brew install git-filter-repo"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "  pip3 install git-filter-repo"
    else
        echo "  Visit: https://github.com/newren/git-filter-repo"
    fi
    exit 1
fi

# Get repository info (with validation)
REPO_DIR=$(pwd)
REPO_NAME=$(basename "$REPO_DIR" | tr -cd '[:alnum:]._-')  # Sanitize repo name
REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || echo "")
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
export CURRENT_BRANCH  # Export for cleanup trap

echo "Repository info:"
echo "  Directory: $REPO_DIR"
echo "  Name: $REPO_NAME"  
echo "  Remote: ${REMOTE_URL:-none}"
echo "  Branch: $CURRENT_BRANCH"
echo ""

# Check for Git LFS
if [ -f .gitattributes ] && grep -q "filter=lfs" .gitattributes 2>/dev/null; then
    # Check if any files from our paths file use LFS
    LFS_FILES_TO_REMOVE=""
    while IFS= read -r path; do
        [[ "$path" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$path" ]] && continue
        [[ "$path" =~ ^(glob|regex): ]] && continue
        
        if grep -q "^${path}.*filter=lfs" .gitattributes 2>/dev/null; then
            LFS_FILES_TO_REMOVE="${LFS_FILES_TO_REMOVE}${path}\n"
        fi
    done < "$PATHS_FILE"
    
    if [ -n "$LFS_FILES_TO_REMOVE" ]; then
        print_warning "These files being removed use Git LFS:"
        echo -e "$LFS_FILES_TO_REMOVE"
        echo ""
        print_question "Do you want to continue?"
        echo "WHY: Git LFS stores large files differently. This script may not remove them completely."
        echo "RECOMMENDATION: Consider running 'git lfs prune' after this script."
        echo ""
        echo "Type 'continue' to proceed with LFS files, or 'exit' to cancel"
        read -rp "> " confirm
        if [ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "continue" ]; then
            exit 1
        fi
    fi
fi

# Check for uncommitted changes
GIT_STATUS=$(git status --porcelain)
if [ -n "$GIT_STATUS" ]; then
    # Check if the only uncommitted file is this script itself
    SCRIPT_BASENAME=$(basename "$0")
    SCRIPT_STATUS=$(echo "$GIT_STATUS" | grep -E "^\\?\\? ${SCRIPT_BASENAME}$" || true)
    OTHER_CHANGES=$(echo "$GIT_STATUS" | grep -v -E "^\\?\\? ${SCRIPT_BASENAME}$" || true)
    
    if [ -n "$OTHER_CHANGES" ]; then
        print_error "You have uncommitted changes."
        echo ""
        echo "WHY: Uncommitted changes will be lost during history rewriting."
        echo "RECOMMENDATION: Commit or stash your changes first:"
        echo "  git add . && git commit -m 'Save work before cleanup'"
        echo "  OR"
        echo "  git stash push -m 'Before cleanup'"
        exit 1
    elif [ -n "$SCRIPT_STATUS" ]; then
        print_warning "This cleanup script ($SCRIPT_BASENAME) is untracked but will be ignored."
    fi
fi

# Check for git worktrees
WORKTREE_COUNT=$(git worktree list 2>/dev/null | wc -l)
if [ "$WORKTREE_COUNT" -gt 1 ]; then
    print_warning "You have additional git worktrees:"
    git worktree list
    echo ""
    print_question "Continue with worktrees present?"
    echo "WHY: Worktrees reference the same repository and will be affected by history rewriting."
    echo "RECOMMENDATION: Remove worktrees first with 'git worktree remove <path>'"
    echo ""
    echo "Type 'continue' to proceed with worktrees, or 'exit' to cancel"
    read -rp "> " confirm
    if [ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "continue" ]; then
        exit 1
    fi
fi

# Check for stashes
STASH_COUNT=$(git stash list 2>/dev/null | wc -l)
if [ "$STASH_COUNT" -gt 0 ]; then
    print_warning "You have $STASH_COUNT stashed changes"
    echo ""
    echo "WHY: Stashes may contain files being removed and could reintroduce them."
    echo "RECOMMENDATION: Review stashes with 'git stash list' and drop any containing test files."
fi

# Check for unpushed commits (safely handle branch names)
if git rev-parse "origin/$CURRENT_BRANCH" &>/dev/null; then
    UNPUSHED=$(git rev-list --count "origin/${CURRENT_BRANCH}"..HEAD 2>/dev/null || echo "0")
    if [ "$UNPUSHED" -gt 0 ]; then
        print_warning "You have $UNPUSHED unpushed commits on $CURRENT_BRANCH"
        echo ""
        print_question "Do you want to continue without pushing?"
        echo "WHY: Unpushed commits will have their hashes changed, making pushing more complex."
        echo "RECOMMENDATION: Push your commits first (recommended):"
        echo "  git push origin \"$CURRENT_BRANCH\""
        echo ""
        echo "Type 'continue' to proceed without pushing, or 'exit' to cancel"
        read -rp "> " confirm
        if [ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "continue" ]; then
            exit 1
        fi
    fi
else
    print_warning "Remote tracking branch not found for $CURRENT_BRANCH"
fi

print_success "Safety checks passed"
echo ""

# Note about remote branches:
# git filter-repo processes ALL branches and refs
print_info "Note: git filter-repo will rewrite ALL branches, not just the current one"

# Check for pull requests before making changes
echo ""
print_info "Checking GitHub for open pull requests..."
echo "Why this matters: History rewriting will break any open pull requests"
echo ""
PR_COUNT=0
OPEN_PRS=""
if [ "$GH_AVAILABLE" = true ]; then
    echo "Querying GitHub API for pull requests..."
    OPEN_PRS=$(gh pr list --limit 100 --json number,title,author 2>/dev/null || echo "")
    if [ -n "$OPEN_PRS" ] && [ "$OPEN_PRS" != "[]" ]; then
        PR_COUNT=$(echo "$OPEN_PRS" | jq -r '. | length' 2>/dev/null || echo "0")
        if [ "$PR_COUNT" -gt 0 ]; then
            print_warning "Found $PR_COUNT open pull request(s) that will break:"
            echo "$OPEN_PRS" | jq -r '.[] | "  PR #\(.number): \(.title) (by \(.author.login))"' 2>/dev/null || echo "  Unable to parse PR data"
            echo ""
            echo "Impact on pull requests:"
            echo "  - They will reference commits that no longer exist"
            echo "  - GitHub will show them as unmergeable"
            echo "  - All review comments and discussions remain but become orphaned"
            echo ""
            echo "RECOMMENDED ACTIONS:"
            echo "  1. Merge important PRs before continuing (best option)"
            echo "  2. Or notify PR authors they'll need to recreate their PRs"
            echo "  3. Or accept that these PRs will need to be manually recreated"
            echo ""
            echo "Learn more: https://docs.github.com/en/pull-requests/collaborating-with-pull-requests"
            echo ""
            echo "Type 'break-prs' to proceed knowing PRs will break, or 'exit' to cancel"
            read -rp "> " pr_confirm
            if [ "$(echo "$pr_confirm" | tr '[:upper:]' '[:lower:]')" != "break-prs" ]; then
                exit 1
            fi
        fi
    fi
else
    # Try to detect PRs from git refs if gh CLI not available
    if [ -d .git/refs/pull ] || git show-ref | grep -q "refs/pull/"; then
        print_warning "Pull requests may exist in this repository"
        echo "Consider checking GitHub for open PRs before proceeding."
        echo ""
        echo "Type 'continue' to proceed anyway, or 'exit' to cancel"
        read -rp "> " pr_confirm
        if [ "$(echo "$pr_confirm" | tr '[:upper:]' '[:lower:]')" != "continue" ]; then
            exit 1
        fi
    fi
fi

print_success "All safety checks completed"
echo ""

# Initialize global variables for later use
export GH_AVAILABLE=false
export PROTECTION_MODIFIED=false
export CURRENT_PROTECTION=""
export ALLOW_FORCE_PUSH="unknown"

# GitHub CLI availability was already checked at the beginning

# Step 2: Display what will be removed
print_info "Step 2: Review files to be removed from history:"
echo "Files specified in: $PATHS_FILE"
echo ""
echo "Preview of paths to remove:"
head -20 "$PATHS_FILE" | grep -v '^#' | grep -v '^$' || true
TOTAL_LINES=$(grep -v '^#' "$PATHS_FILE" | grep -c -v '^$' || echo "0")
if [ "$TOTAL_LINES" -gt 20 ]; then
    echo "... and $((TOTAL_LINES - 20)) more paths"
fi
echo ""

# Step 3: Critical warnings and branch check
print_info "Step 3: Review critical warnings"
echo ""
print_warning "CRITICAL: Please read these warnings from GitHub:"
echo "- This will PERMANENTLY rewrite git history"
echo "- All commit SHAs will change" 
echo "- Open pull requests will become invalid"
echo "- Signed commits will lose their signatures"
echo "- Branch protections must be temporarily disabled"
echo "- All collaborators must re-clone (not pull) the repository"
echo ""

# Check if user is on main/master
if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
    print_warning "You are on the $CURRENT_BRANCH branch!"
    echo ""
    print_question "Are you SURE you want to rewrite the $CURRENT_BRANCH branch history?"
    echo ""
    echo "WHY: This operation affects ALL branches and ALL history"
    echo "     Files are removed from the ENTIRE repository, not just $CURRENT_BRANCH"
    echo ""
    echo "IMPORTANT: git-filter-repo rewrites ALL branches:"
    echo "           - Every branch gets new commit IDs"
    echo "           - All tags are updated"
    echo "           - The entire repository history changes"
    echo ""
    echo "RECOMMENDATION: Only proceed if:"
    echo "  1. You understand this will break all clones and forks"
    echo "  2. All collaborators have been notified"
    echo "  3. You're prepared to handle the disruption"
    echo ""
    echo "Type 'rewrite-history' to proceed, or 'exit' to cancel"
    read -rp "> " confirm
    if [ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "rewrite-history" ]; then
        exit 1
    fi
fi

# Show repository info before next section
echo ""
print_info "Repository: $REMOTE_URL"
print_info "Current branch: $CURRENT_BRANCH"
echo ""

# Step 4: Create mandatory backup
print_info "Step 4: Backup creation"
echo ""

# Generate timestamp once to ensure backup and log have matching timestamps
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Both backup and log go in parent directory, next to the repo
BACKUP_DIR="${REPO_DIR}.backup-${TIMESTAMP}"

# Create log file with timestamp - default next to backup
if [ -n "${USER_LOG_FILE:-}" ]; then
    LOG_FILE="$USER_LOG_FILE"
else
    # Default: put log next to backup with matching timestamp
    # Both are in parent directory, safe from repo modifications
    LOG_FILE="${REPO_DIR}.cleanup-log-${TIMESTAMP}.log"
fi
export LOG_FILE

# Now we can announce the log file location
echo "Log file: $LOG_FILE"

# Start logging - save original stdout/stderr
exec 3>&1 4>&2
# Tee all output to log file
exec > >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

if [ "$DRY_RUN" = true ]; then
    print_info "DRY RUN: Skipping backup creation"
else
    print_info "Creating mandatory full backup..."
    
    # Check available disk space with safety margin
    AVAILABLE_SPACE=$(df -k . | tail -1 | awk '{print $4}')
    REPO_SIZE=$(du -sk . 2>/dev/null | cut -f1 || echo "0")
    REQUIRED_SPACE=$((REPO_SIZE * 3 / 2))  # 1.5x for safety margin
    
    if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
        print_error "Insufficient disk space for backup"
        echo "Repository size: $((REPO_SIZE / 1024))MB"
        echo "Required (with margin): $((REQUIRED_SPACE / 1024))MB"
        echo "Available: $((AVAILABLE_SPACE / 1024))MB"
        echo ""
        echo "WHY: A backup is mandatory and we need extra space for the operation."
        echo "RECOMMENDATION: Free up at least $(( (REQUIRED_SPACE - AVAILABLE_SPACE) / 1024 ))MB."
        exit 1
    fi
    
    print_info "Creating backup (this may take a moment)..."
    # Enter critical section for backup
    CRITICAL_OPERATION=true
    if ! cp -a "$REPO_DIR" "$BACKUP_DIR"; then
        CRITICAL_OPERATION=false
        print_error "Failed to create backup!"
        echo "Possible causes:"
        echo "  - Insufficient disk space"
        echo "  - Permission denied"
        echo "  - File system errors"
        exit 1
    fi
    CRITICAL_OPERATION=false
    
    # Verify backup
    if [ ! -d "$BACKUP_DIR/.git" ]; then
        print_error "Backup verification failed - .git directory missing!"
        rm -rf "$BACKUP_DIR" 2>/dev/null || true
        exit 1
    fi
    if [ ! -f "$BACKUP_DIR/.git/HEAD" ] || [ ! -d "$BACKUP_DIR/.git/objects" ]; then
        print_error "Backup verification failed - git repository structure incomplete!"
        rm -rf "$BACKUP_DIR" 2>/dev/null || true
        exit 1
    fi
    
    print_success "Backup created and verified at: $BACKUP_DIR"
    echo ""
    print_warning "IMPORTANT: Do NOT delete this backup until you've verified everything works!"
    echo ""
fi

# Check branch protection status early (if gh CLI available)
if [ "$GH_AVAILABLE" = true ]; then
    echo ""
    print_info "Checking GitHub branch protection rules..."
    echo "Why: Protected branches block force-pushes, which we need to do"
    echo "What to expect:"
    echo "  - Most personal repositories: No protection (normal)"
    echo "  - Organization repositories: May have protection"
    echo ""
    echo "Querying GitHub API: repos/{owner}/{repo}/branches/$CURRENT_BRANCH/protection"
    PROTECTION_STATUS=$(gh api "repos/{owner}/{repo}/branches/$CURRENT_BRANCH/protection" 2>&1 || echo "")
    
    # Log the raw response for debugging
    echo "GitHub API response (saved for debugging):"
    echo "$PROTECTION_STATUS" | head -20
    echo ""
    
    if echo "$PROTECTION_STATUS" | grep -q "Branch not protected"; then
        print_success "Branch has no protection rules"
        echo "This is typical for personal repositories"
        echo "No extra steps needed for force-push"
        export PROTECTION_EXISTS=false
    elif echo "$PROTECTION_STATUS" | grep -q "Not Found"; then
        print_info "Cannot verify protection status (insufficient permissions)"
        echo "The push step will reveal if protection exists"
        export PROTECTION_EXISTS=false
    elif echo "$PROTECTION_STATUS" | grep -q "message.*API"; then
        print_warning "GitHub API access may be restricted for this repository"
        export PROTECTION_EXISTS=false
    else
        print_warning "Branch protection rules are ENABLED"
        echo "What this means:"
        echo "  - GitHub currently blocks force-pushes to this branch"
        echo "  - We'll need to temporarily allow force-pushes"
        echo "  - Protection will be restored after pushing"
        export PROTECTION_EXISTS=true
        # Save the full protection settings regardless of force push status
        export CURRENT_PROTECTION="$PROTECTION_STATUS"
        echo "Saved protection settings for potential restoration"
        
        # Check if force pushes are allowed
        ALLOW_FORCE=$(echo "$PROTECTION_STATUS" | jq -r '.allow_force_pushes.enabled' 2>/dev/null || echo "unknown")
        export ALLOW_FORCE_PUSH="$ALLOW_FORCE"
        
        if [ "$ALLOW_FORCE" = "true" ]; then
            print_info "Good news: Force pushes are already allowed"
            echo "No protection changes needed"
        elif [ "$ALLOW_FORCE" = "false" ]; then
            print_warning "Force pushes are currently blocked"
            echo "The script will:"
            echo "  1. Temporarily allow force pushes when you're ready to push"
            echo "  2. Push the cleaned history"
            echo "  3. Restore the protection automatically"
        fi
    fi
    echo ""
fi

# Step 5: Credential check
print_info "Step 5: Security check for exposed credentials"
echo ""
print_warning "CRITICAL SECURITY WARNING:"
echo ""
echo "GitHub states: 'You should consider any data committed to Git to be compromised'"
echo "Source: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository"
echo ""
echo "Why this is critical:"
echo "  - Automated bots continuously scan GitHub for exposed secrets"
echo "  - Credentials can be harvested within minutes of exposure"
echo "  - Even brief exposure should be considered a security breach"
echo ""
echo "How exposed data persists:"
echo "  - Old commits remain accessible via direct URLs"
echo "  - Forks and clones contain permanent copies"
echo "  - GitHub caches may retain data for 90 days"
echo "  - Search engines may have indexed the content"
echo ""
if [ "$DRY_RUN" = false ]; then
    print_question "Have you rotated/revoked any exposed secrets?"
    echo ""
    echo "REQUIRED ACTIONS if files contained passwords, keys, or tokens:"
    echo "  1. Change all passwords IMMEDIATELY"
    echo "  2. Revoke and regenerate ALL API keys"
    echo "  3. Review access logs for unauthorized use"
    echo "  4. Consider ALL credentials COMPROMISED"
    echo ""
    echo "This script removes files but CANNOT undo past exposure"
    echo ""
    echo "Type: 'rotated' (handled any secrets), 'skip' (no secrets), or 'exit' (need to handle)"
    read -rp "> " cred_confirm
    cred_confirm_lower=$(echo "$cred_confirm" | tr '[:upper:]' '[:lower:]')
    if [ "$cred_confirm_lower" = "exit" ]; then
        print_error "Please rotate all credentials first, then run this script again."
        exit 1
    elif [ "$cred_confirm_lower" != "rotated" ] && [ "$cred_confirm_lower" != "skip" ]; then
        print_error "Please type: rotated, skip, or exit"
        exit 1
    fi
fi

# Step 6: Final confirmation
# Step 6: Final confirmation
print_info "Step 6: Final confirmation before proceeding"
if [ "$DRY_RUN" = false ]; then
    echo ""
    print_warning "FINAL CONFIRMATION"
    echo ""
    echo "This will:"
    echo "  1. Remove all test/demo files from git history"
    echo "  2. Change all commit SHAs"
    echo "  3. Require force-pushing to GitHub"
    echo "  4. Require all collaborators to re-clone"
    echo ""
    echo "Backup location: $BACKUP_DIR"
    echo ""
    echo ""
    echo "Type exactly: REMOVE FILES FROM HISTORY"
    echo "Or type 'cancel' to exit safely"
    read -rp "> " confirm
    if [ "$confirm" != "REMOVE FILES FROM HISTORY" ]; then
        print_info "Operation cancelled. No changes made."
        exit 0
    fi
fi

# Step 7: Prepare list of files to remove
print_info "Step 7: Preparing list of files to remove"

if [ "$USER_PROVIDED_PATHS" = true ]; then
    # User provided their own paths file
    print_info "Using user-provided paths file: $PATHS_FILE"
    echo "Contents preview:"
    head -20 "$PATHS_FILE"
    TOTAL_LINES=$(wc -l < "$PATHS_FILE")
    if [ "$TOTAL_LINES" -gt 20 ]; then
        echo "... and $((TOTAL_LINES - 20)) more lines"
    fi
    echo ""
    
    # Validate paths file content
    if [ ! -s "$PATHS_FILE" ]; then
        print_error "Paths file is empty!"
        exit 1
    fi

    # Count valid paths (non-comment, non-empty lines)
    VALID_PATHS=$(grep -v '^#' "$PATHS_FILE" | grep -c -v '^$' || echo "0")
    if [ "$VALID_PATHS" -eq 0 ]; then
        print_error "No valid paths found in paths file!"
        exit 1
    fi

    print_info "Found $VALID_PATHS paths to remove from history"
    echo ""
else
    # No paths file provided - this is now required
    print_error "No paths file provided!"
    echo ""
    echo "This script requires a paths file to specify which files to remove."
    echo "Use --permanently-remove-paths-from-file FILE to provide a list of files to remove."
    echo ""
    echo "Example paths file format:"
    echo "  test_directory/"
    echo "  demo_files/"
    echo "  unwanted_file.txt"
    echo "  *.log"
    echo "  # Comments start with #"
    echo ""
    echo "Run '$SCRIPT_NAME --help' for more information."
    exit 1
fi

# Step 8: Run git filter-repo
print_info "Step 8: Execute history cleanup"
echo ""
echo "About to use git-filter-repo (GitHub's recommended tool)"
echo "Documentation: https://github.com/newren/git-filter-repo"
echo ""
echo "This process will:"
echo "  - Analyze all commits in your repository"
echo "  - Remove specified files from each commit"
echo "  - Recalculate all commit hashes (permanent change)"
echo "  - Update all references (branches, tags)"
echo ""
print_warning "After this step, your local history is permanently changed"
echo ""
if [ "$DRY_RUN" = true ]; then
    print_info "DRY RUN: Would remove these files from history:"
    echo ""
    grep -v '^#' "$PATHS_FILE" | grep -v '^$' || true
    echo ""
    print_info "DRY RUN: No changes made to repository"
else
    print_info "Running git filter-repo (this may take several minutes)..."
    echo "Progress will be shown below:"
    echo ""
    print_warning "CRITICAL OPERATION STARTING - Ctrl+C is now DISABLED"
    echo "Interruption will corrupt your repository. Please wait for completion."
    echo ""
    
    # Enter critical section
    CRITICAL_OPERATION=true
    
    # Create a marker file to indicate cleanup is in progress
    CLEANUP_MARKER=".git/cleanup-in-progress"
    echo "$BACKUP_DIR" > "$CLEANUP_MARKER"
    
    # SAFETY: Default to dry-run unless explicitly confirmed for real cleanup
    # FILTER_REPO_MODE defaults to "--dry-run" for safety
    FILTER_REPO_MODE="${FILTER_REPO_MODE:---dry-run}"
    
    # Only remove --dry-run flag if this is explicitly a real destructive run
    if [ "$DRY_RUN" = false ]; then
        FILTER_REPO_MODE=""
    fi
    
    # Note: --force is required for in-place operation
    # Using --sensitive-data-removal for thorough cleanup (optional for non-sensitive data)
    if ! git filter-repo $FILTER_REPO_MODE --sensitive-data-removal --invert-paths --paths-from-file "$PATHS_FILE" --force; then
        print_error "git filter-repo failed!"
        echo ""
        echo "TO RESTORE FROM BACKUP:"
        echo "  cd .."
        echo "  rm -rf \"$REPO_NAME\""
        echo "  cp -a \"$BACKUP_DIR\" \"$REPO_NAME\""
        echo "  cd \"$REPO_NAME\""
        rm -f "$CLEANUP_MARKER" 2>/dev/null || true
        exit 1
    fi
    
    # Remove marker file on success
    rm -f "$CLEANUP_MARKER" 2>/dev/null || true
    
    print_success "git filter-repo completed successfully"
    
    # Exit critical section
    CRITICAL_OPERATION=false
    echo "Ctrl+C is now enabled again"
    echo ""
    
    # Step 9: Verify results
    print_info "Step 9: Verifying cleanup..."
    echo "Checking that files were successfully removed from history..."
    
    # Get size comparison
    ORIGINAL_SIZE=$(du -sh "$BACKUP_DIR/.git" 2>/dev/null | cut -f1 || echo "unknown")
    NEW_SIZE=$(du -sh .git | cut -f1)
    
    echo "Original .git size: $ORIGINAL_SIZE"
    echo "New .git size: $NEW_SIZE"
    
    # Check for remaining files
    echo "Scanning repository history for any remaining test/demo files..."
    # Verify files from paths file were removed
    print_info "Checking removal of files from paths file..."
    CHECKED=0
    FAILED=0
    
    # Ensure paths file is still readable
    if [ ! -r "$PATHS_FILE" ]; then
        print_warning "Cannot read paths file for verification: $PATHS_FILE"
        return 0
    fi
    
    while IFS= read -r path; do
        [[ "$path" =~ ^[[:space:]]*# ]] && continue  # Skip comments
        [[ -z "$path" ]] && continue                # Skip empty lines
        [[ "$path" =~ ^(glob|regex): ]] && continue # Skip complex patterns
        
        ((CHECKED++))  # Count only valid paths
        clean_path="${path%/}"  # Remove trailing slash
        
        # Use -- to ensure path isn't interpreted as option
        # Redirect stderr to avoid git warnings about non-existent paths
        if git log --all --name-status -- "$clean_path" 2>/dev/null | head -1 | grep -q .; then
            print_warning "Still in history: $clean_path"
            ((FAILED++))
        fi
    done < "$PATHS_FILE"
    
    if [ "$FAILED" -eq 0 ]; then
        print_success "All $CHECKED checked files successfully removed from history!"
    else
        print_warning "$FAILED of $CHECKED files may still be in history"
    fi
    
    # Step 10: Re-add remote (filter-repo removes it for safety)
    if [ -n "$REMOTE_URL" ]; then
        echo ""
        print_info "Re-adding remote origin..."
        if ! git remote get-url origin &>/dev/null; then
            git remote add origin "$REMOTE_URL"
        else
            git remote set-url origin "$REMOTE_URL"
        fi
        print_success "Remote restored"
    fi
    
    # Step 11: Automated verification
    echo ""
    print_info "Step 11: Running automated verification..."
    echo ""
    
    # Verify cleanup
    print_info "Checking recent commits..."
    git log --oneline -10
    echo ""
    
    print_success "Cleanup completed! Check the verification results above."
    echo ""
    
    # Note: PR checking was already done before cleanup started
    if [ "$PR_COUNT" -gt 0 ]; then
        print_info "Note: $PR_COUNT pull request(s) were affected by this rewrite"
    fi
    
    # Step 12: Final instructions
    echo ""
    echo "=============================================="
    print_success "History cleanup completed successfully!"
    echo "=============================================="
    echo ""
    
    # Offer to push changes
    print_question "Ready to push your rewritten history to GitHub?"
    echo ""
    echo "Current state:"
    echo "  LOCAL (your computer):"
    echo "    - History HAS BEEN permanently rewritten"
    echo "    - All commit SHAs HAVE CHANGED"
    echo "    - Original saved in backup: $BACKUP_DIR"
    echo ""
    echo "  GITHUB (remote):"
    echo "    - Still has the ORIGINAL history"
    echo "    - Still contains the files you want removed"
    echo "    - No changes made there yet"
    echo ""
    echo "What pushing does:"
    echo "  - Overwrites GitHub's history with your local version"
    echo "  - Makes the file removal visible to everyone"
    echo "  - Breaks any existing pull requests"
    echo ""
    echo "If you DON'T push:"
    echo "  - GitHub keeps the old history (with sensitive files)"
    echo "  - Your local changes remain but aren't shared"
    echo "  - You can restore from backup to undo everything"
    echo ""
    echo "Type 'push' to push now, or 'skip' to push manually later"
    read -rp "> " push_confirm
    push_confirm="$(echo "$push_confirm" | tr '[:upper:]' '[:lower:]')"
    if [ "$push_confirm" = "push" ]; then
        PUSHED=false
        MAX_RETRIES=3
        RETRY_COUNT=0
        
        while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$PUSHED" = false ]; do
            print_info "Pushing changes to GitHub (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
            
            PUSH_OUTPUT=$(mktemp "$LOCK_DIR/push-output-XXXXXX" 2>/dev/null) || PUSH_OUTPUT=""
            if [ -z "$PUSH_OUTPUT" ]; then
                print_error "Failed to create temporary file for push output"
                break
            fi
            # Enter critical section for push
            CRITICAL_OPERATION=true
            echo "Starting force push (Ctrl+C disabled during transfer)..."
            if git push --force --mirror origin 2>&1 | tee "$PUSH_OUTPUT"; then
                CRITICAL_OPERATION=false
                print_success "Successfully pushed all changes to GitHub!"
                PUSHED=true
                rm -f "$PUSH_OUTPUT"
            else
                CRITICAL_OPERATION=false
                RETRY_COUNT=$((RETRY_COUNT + 1))
                if grep -q "protected branch" "$PUSH_OUTPUT" 2>/dev/null; then
                    print_error "Push failed due to branch protection!"
                    echo ""
                    
                    # Only try to modify protection if it exists
                    if [ "${PROTECTION_EXISTS:-false}" = true ] && [ "${PROTECTION_MODIFIED:-false}" = false ] && [ "$GH_AVAILABLE" = true ]; then
                        # If we don't have protection settings, fetch them now
                        if [ -z "$CURRENT_PROTECTION" ]; then
                            print_info "Fetching current branch protection settings..."
                            echo "This is needed to restore protection after force push"
                            PROTECTION_STATUS=$(gh api "repos/{owner}/{repo}/branches/$CURRENT_BRANCH/protection" 2>&1 || echo "")
                            if ! echo "$PROTECTION_STATUS" | grep -q "Not Found" && ! echo "$PROTECTION_STATUS" | grep -q "Branch not protected"; then
                                export CURRENT_PROTECTION="$PROTECTION_STATUS"
                            fi
                        fi
                        
                        if [ -n "$CURRENT_PROTECTION" ]; then
                            echo "Type 'enable' to automatically handle protection, or 'skip' for manual"
                            read -rp "> " auto_enable
                            if [ "$(echo "$auto_enable" | tr '[:upper:]' '[:lower:]')" = "enable" ]; then
                                print_info "Attempting to enable force pushes..."
                                # Re-verify we haven't already modified it (race condition check)
                                if [ "${PROTECTION_MODIFIED:-false}" = true ]; then
                                    print_warning "Protection already modified, skipping"
                                elif gh api -X PUT "repos/{owner}/{repo}/branches/$CURRENT_BRANCH/protection" \
                                    --input - <<< "$(echo "$CURRENT_PROTECTION" | jq '.allow_force_pushes.enabled = true')" 2>/dev/null; then
                                    echo "Protection modification attempt completed"
                                    # Verify the change was applied
                                    VERIFY_STATUS=$(gh api "repos/{owner}/{repo}/branches/$CURRENT_BRANCH/protection" 2>/dev/null || echo "")
                                    if echo "$VERIFY_STATUS" | jq -r '.allow_force_pushes.enabled' 2>/dev/null | grep -q "true"; then
                                        print_success "Force pushes enabled temporarily and verified"
                                        echo "PROTECTION_MODIFIED=true at $(date)"
                                        export PROTECTION_MODIFIED=true
                                    else
                                        print_warning "Protection update may not have applied correctly"
                                        echo "PROTECTION_MODIFIED=true (failed verification) at $(date)"
                                        export PROTECTION_MODIFIED=true  # Still mark as modified to ensure restoration attempt
                                    fi
                                    # Continue the retry loop
                                else
                                    print_error "Failed to modify branch protection automatically"
                                    echo "Protection modification failed at $(date)"
                                fi
                            fi
                        fi
                    fi
                    
                    if [ "${PROTECTION_EXISTS:-false}" = true ] && [ "${PROTECTION_MODIFIED:-false}" = false ]; then
                        echo "To fix this manually:"
                        echo "1. Go to: Settings → Branches → Edit rules"
                        echo "2. Enable 'Allow force pushes'"
                        echo "3. Save changes"
                        echo ""
                        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                            if [ "$GH_AVAILABLE" = true ]; then
                                echo "Type 'open' to open GitHub settings, or 'skip' to continue"
                                read -rp "> " open_gh
                                if [ "$(echo "$open_gh" | tr '[:upper:]' '[:lower:]')" = "open" ]; then
                                    gh repo view --web
                                fi
                            fi
                            echo "Type 'retry' to try pushing again, or 'stop' to give up"
                            read -rp "> " retry_confirm
                            if [ "$(echo "$retry_confirm" | tr '[:upper:]' '[:lower:]')" != "retry" ]; then
                                rm -f "$PUSH_OUTPUT"
                                break
                            fi
                        fi
                    elif [ "${PROTECTION_EXISTS:-false}" = false ]; then
                        print_error "Push failed (not due to branch protection)"
                        echo ""
                        echo "Common causes:"
                        echo "  - Network connectivity issues"
                        echo "  - GitHub authentication expired (run: gh auth refresh)"
                        echo "  - Insufficient repository permissions"
                        echo "  - GitHub service issues"
                        echo ""
                        echo "Troubleshooting guide:"
                        echo "https://docs.github.com/en/get-started/using-git/troubleshooting-common-issues"
                        echo ""
                        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                            echo "Type 'retry' to try again, or 'stop' to give up"
                            read -rp "> " retry_confirm
                            if [ "$(echo "$retry_confirm" | tr '[:upper:]' '[:lower:]')" != "retry" ]; then
                                rm -f "$PUSH_OUTPUT"
                                break
                            fi
                        fi
                    fi
                else
                    print_error "Push failed! Check your network connection and GitHub credentials."
                    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                        echo "Retrying in 5 seconds..."
                        sleep 5
                    fi
                fi
                rm -f "$PUSH_OUTPUT"
            fi
        done
        
        if [ "$PUSHED" = false ]; then
            print_error "Push failed after $MAX_RETRIES attempts."
            print_info "To push manually later, run:"
            echo "  git push --force --mirror origin"
        fi
        
        # Always restore GitHub branch protection if we modified it (whether push succeeded or failed)
        restore_github_branch_protection_rules
    else
        print_info "Skipping push. You'll need to push manually."
        PUSHED=false
        # Still restore GitHub protection if we modified it
        restore_github_branch_protection_rules
    fi
    echo ""
    
    print_warning "CRITICAL NEXT STEPS:"
    echo ""
    echo "What has been done:"
    if [ "$PUSHED" = false ]; then
        echo "  - Your LOCAL history is rewritten (permanent locally)"
        echo "  - GitHub still has ORIGINAL history (no remote changes)"
        echo "  - Backup exists at: $BACKUP_DIR"
        print_warning "Files are STILL visible on GitHub until you push"
    else
        echo "  - Your LOCAL history is rewritten"
        echo "  - GitHub's history is NOW rewritten (permanent remotely)"
        echo "  - Pull requests are broken"
        echo "  - Other clones are now incompatible"
        print_success "File removal is complete on GitHub"
    fi
    echo ""
    
    # Handle PR closing with gh CLI
    if [ "$GH_AVAILABLE" = true ] && [ "$PR_COUNT" -gt 0 ] && [ "$PUSHED" = true ]; then
        print_question "Would you like to automatically close all open PRs?"
        echo "This will close all PRs with a comment explaining the history rewrite."
        echo "Type 'close' to close all PRs automatically, or 'skip' to handle manually"
        read -rp "> " close_prs
        if [ "$(echo "$close_prs" | tr '[:upper:]' '[:lower:]')" = "close" ]; then
            print_info "Closing all open pull requests..."
            PR_NUMBERS=$(gh pr list --limit 100 --json number -q '.[].number' 2>/dev/null || echo "")
            CLOSED_COUNT=0
            for pr_num in $PR_NUMBERS; do
                if gh pr close "$pr_num" --comment "This PR has been automatically closed because the repository history was rewritten. Please create a new PR with your changes." 2>/dev/null; then
                    CLOSED_COUNT=$((CLOSED_COUNT + 1))
                fi
            done
            print_success "Closed $CLOSED_COUNT pull requests"
            echo ""
            PR_COUNT=0  # Reset since we closed them
        fi
    fi
    
    if [ "$PUSHED" = false ]; then
        STEP_NUM=1
        
        # Provide manual instructions for push
        echo "$STEP_NUM. PUSH to GitHub:"
        echo "   git push --force --mirror origin"
        echo "   # Note: --mirror pushes all refs and removes remote refs not present locally"
        echo ""
        if [ -n "$CURRENT_PROTECTION" ] && echo "$CURRENT_PROTECTION" | jq -r '.allow_force_pushes.enabled' 2>/dev/null | grep -q "false"; then
            echo "   Note: Branch protection may block this. You may need to:"
            echo "   - Enable 'Allow force pushes' in Settings → Branches → Edit rules"
            echo "   - Or use the automated protection management in the retry prompts"
        fi
        echo ""
        STEP_NUM=$((STEP_NUM + 1))
        
        if [ "${PROTECTION_MODIFIED:-false}" = true ]; then
            echo "$STEP_NUM. RE-DISABLE force pushes (restore protection):"
            echo "   The script enabled force pushes. After pushing, restore protection:"
            if [ "$GH_AVAILABLE" = true ]; then
                echo "   Option 1: Let the script restore it during push retry"
                echo "   Option 2: Manually restore:"
                echo "     gh repo view --web"
                echo "     Go to: Settings → Branches → Edit rules → Disable 'Allow force pushes'"
            else
                echo "   Go to: Settings → Branches → Edit rules → Disable 'Allow force pushes'"
            fi
        elif [ "$ALLOW_FORCE_PUSH" = "false" ]; then
            echo "$STEP_NUM. Adjust branch protection if needed:"
            echo "   If you need to enable force pushes temporarily:"
            echo "   Go to: Settings → Branches → Edit rules → Enable 'Allow force pushes'"
            echo "   Remember to disable it again after pushing"
        fi
        STEP_NUM=$((STEP_NUM + 1))
    else
        NEXT_STEP=1
        if [ "$PR_COUNT" -gt 0 ] && [ "$GH_AVAILABLE" = false ]; then
            echo "$NEXT_STEP. CLOSE all affected pull requests on GitHub (they are now broken)"
            echo ""
            NEXT_STEP=$((NEXT_STEP + 1))
        fi
        
        echo "$NEXT_STEP. RE-ENABLE branch protection rules (if you disabled them)"
        echo "   Go to: Settings → Branches → Edit rules → Re-enable protections"
        
        if [ "$GH_AVAILABLE" = true ]; then
            echo ""
            echo "Type 'open' to open GitHub settings, or 'skip' to do it later"
            read -rp "> " open_protect
            if [ "$(echo "$open_protect" | tr '[:upper:]' '[:lower:]')" = "open" ]; then
                gh repo view --web
            fi
        fi
        NEXT_STEP=$((NEXT_STEP + 1))
    fi
    echo ""
    
    # Show next steps based on whether we pushed
    if [ "$PUSHED" = false ]; then
        echo "$STEP_NUM. CONTACT GitHub Support (for complete removal):"
        FINAL_STEP=$((STEP_NUM + 1))
    else
        echo "$NEXT_STEP. CONTACT GitHub Support (for complete removal):"
        FINAL_STEP=$((NEXT_STEP + 1))
    fi
    echo "   - Go to: https://support.github.com/contact"
    echo "   - Select: 'Removing sensitive data'"
    echo "   - Provide: Repository URL and list of removed files"
    echo ""
    echo "   Why contact support: GitHub caches data for up to 90 days"
    echo "   Learn more: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository#fully-removing-the-data-from-github"
    echo ""
    
    # Generate collaborator notification template
    if [ "$PUSHED" = false ]; then
        echo "$FINAL_STEP. NOTIFY all collaborators (after pushing):"
        FINAL_STEP=$((FINAL_STEP + 1))
    else
        echo "$FINAL_STEP. NOTIFY all collaborators NOW:"
        FINAL_STEP=$((FINAL_STEP + 1))
    fi
    echo ""
    print_info "Sample notification email:"
    echo "---"
    echo "Subject: URGENT: Repository history rewritten - re-clone required"
    echo ""
    echo "The git history for $REPO_NAME has been rewritten to remove test/demo files."
    echo ""
    echo "IMPORTANT: Do NOT run 'git pull' - it will fail or corrupt your local repo."
    echo ""
    echo "Required actions:"
    echo "1. Save any uncommitted work outside the repository"
    echo "2. Delete your local copy: rm -rf $REPO_NAME"
    echo "3. Re-clone: git clone $REMOTE_URL"
    echo "4. Reapply any saved work"
    echo ""
    echo "All pull requests have been invalidated and need to be recreated."
    echo "---"
    echo ""
    
    echo "$FINAL_STEP. KEEP the backup until everything is verified:"
    echo "   Backup location: $BACKUP_DIR"
    echo ""
    FINAL_STEP=$((FINAL_STEP + 1))
    
    echo "$FINAL_STEP. After verification (in a few days):"
    echo "   rm -rf $BACKUP_DIR"
    echo "   rm -f $0"
    echo ""
    
    print_warning "DO NOT DELETE THE BACKUP until you're 100% certain everything works!"
fi

echo ""
echo "=============================================="
print_success "Script completed!"
echo "=============================================="
echo "Log file saved: $LOG_FILE"
echo "Completed at: $(date)"

# Note: stdout/stderr will be restored by the cleanup trap
# This ensures all output is logged until the very end