#!/bin/bash
#
# Test Script for Git History Cleanup Helper
# Tests the cleanup_git_history.sh script functionality
#
# Copyright 2025 Andrew Hundt
# Licensed under the Apache License, Version 2.0

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# === PLATFORM DETECTION ===
detect_platform() {
    case "${OSTYPE:-unknown}" in
        linux*)   PLATFORM="linux" ;;
        darwin*)  PLATFORM="macos" ;;
        msys*|cygwin*) PLATFORM="windows" ;;
        *)        PLATFORM="unknown" ;;
    esac
    export PLATFORM
    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "Platform detected: $(printf %q "$PLATFORM")"
    fi
}

# Test configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="${SCRIPT_DIR}/cleanup_git_history.sh"
TEST_DIR=""
CLEANUP_AFTER=true
VERBOSE=false
FAILED_TESTS=0
PASSED_TESTS=0

# Detect platform at startup
detect_platform

# === UTILITY FUNCTIONS ===
log_verbose() {
    if [ "${VERBOSE:-false}" = "true" ]; then
        echo -e "${GRAY}[DEBUG] $*${NC}" >&2
    fi
}

log_error() {
    echo -e "${RED}❌ ERROR: $*${NC}" >&2
}

log_success() {
    echo -e "${GREEN}✅ $*${NC}"
}

log_info() {
    echo -e "${BLUE}ℹ️  $*${NC}"
}

# Safe directory/file removal with trash fallback
safe_remove() {
    local path="$1"

    # Return early if path doesn't exist
    [ ! -e "$path" ] && return 0
    
    # CRITICAL: Refuse to operate on symlinks
    if [ -L "$path" ]; then
        log_error "Refusing to remove symlink: $path"
        return 1
    fi
    
    # Get canonical path to ensure we're within test directory
    local canonical_path
    if [ -d "$path" ]; then
        canonical_path=$(cd "$path" 2>/dev/null && pwd -P)
    else
        canonical_path=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)
    fi
    
    if [ -z "$canonical_path" ]; then
        log_error "Cannot determine canonical path for: $path"
        return 1
    fi
    
    # Ensure path is within test directory (or IS the test directory)
    if [ -n "${TEST_DIR:-}" ]; then
        local test_dir_canonical
        test_dir_canonical=$(cd "$TEST_DIR" 2>/dev/null && pwd -P || echo "$TEST_DIR")
        
        # Allow removal if it's the test directory itself or within it
        if [[ "$canonical_path" != "$test_dir_canonical" ]] && 
           [[ ! "$canonical_path" =~ ^"$test_dir_canonical"/ ]]; then
            log_error "Path escapes test directory: $path"
            return 1
        fi
    fi

    log_verbose "Removing: $path"

    # Use trash if available, otherwise fall back to rm
    # Always silent and never fail
    if command -v trash >/dev/null 2>&1; then
        trash "$path" >/dev/null 2>&1 || true
        log_verbose "Moved to trash: $path"
    else
        rm -rf "$path" >/dev/null 2>&1 || true
        log_verbose "Removed: $path"
    fi
}

# Cross-platform file size
get_file_size() {
    local file="$1"
    case "$PLATFORM" in
        macos)   stat -f%z "$file" 2>/dev/null || echo "0" ;;
        linux)   stat -c%s "$file" 2>/dev/null || echo "0" ;;
        *)       wc -c < "$file" 2>/dev/null | tr -d ' ' || echo "0" ;;
    esac
}

human_readable_size() {
    local size=$1
    if [[ $size -gt 1048576 ]]; then
        echo "$((size / 1048576))MB"
    elif [[ $size -gt 1024 ]]; then
        echo "$((size / 1024))KB"
    else
        echo "${size}B"
    fi
}

# Print functions (keeping for compatibility)
print_test() {
    echo -e "${BLUE}TEST:${NC} $1"
}

print_pass() {
    log_success "PASS: $1"
    ((PASSED_TESTS++)) || true
}

print_fail() {
    log_error "FAIL: $1"
    ((FAILED_TESTS++)) || true
}

print_info() {
    log_info "$1"
}

# Additional safety utilities
validate_safe_path() {
    local path="$1"
    local description="${2:-path}"
    
    # Check for dangerous patterns
    case "$path" in
        /*) ;; # Absolute path is OK
        *) log_error "$description must be an absolute path: $path"; return 1 ;;
    esac
    
    # Check for dangerous directories (with or without trailing slash)
    case "$path" in
        /|/home|/root|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/opt|/opt/*|/System|/System/*|/Library|/Library/*)
            log_error "$description points to system directory: $path"
            return 1
            ;;
    esac
    
    # Check for directory traversal attempts
    if [[ "$path" =~ \.\. ]]; then
        log_error "$description contains directory traversal: $path"
        return 1
    fi
    
    # Check for symlinks
    if [ -L "$path" ]; then
        log_error "$description is a symlink: $path"
        return 1
    fi
    
    return 0
}

# Show usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --no-cleanup    Don't cleanup test directories after completion"
    echo "  --verbose       Show detailed output"
    echo "  -h, --help      Show this help message"
    echo ""
    echo "This script tests the Git History Cleanup Helper functionality"
    echo "It creates temporary test repositories and verifies the cleanup process"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-cleanup)
            CLEANUP_AFTER=false
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Cleanup function with safety checks
cleanup() {
    log_verbose "Cleanup called with TEST_DIR=${TEST_DIR:-<not set>}"
    
    if [ "$CLEANUP_AFTER" = true ] && [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        # CRITICAL SAFETY: Validate TEST_DIR is safe to delete
        # Must be under /tmp or /var/tmp and contain our marker
        # Escape TMPDIR for use in regex to prevent injection
        local escaped_tmpdir
        escaped_tmpdir=$(printf '%s\n' "${TMPDIR:-/tmp}" | sed 's/[[\.\*\^$()+?{|]/\\&/g')
        # Remove trailing slash from escaped tmpdir
        escaped_tmpdir="${escaped_tmpdir%/}"
        if [[ "$TEST_DIR" =~ ^(/tmp|/var/tmp|/private/tmp|/var/folders)/git-cleanup-test\.[A-Za-z0-9]+$ ]] || 
           [[ "$TEST_DIR" =~ ^"$escaped_tmpdir"/git-cleanup-test\.[A-Za-z0-9]+$ ]]; then
            # Additional safety: check for our marker file
            if [ -f "$TEST_DIR/.git-cleanup-test-marker" ]; then
                log_info "Cleaning up test directory: $TEST_DIR"
                safe_remove "$TEST_DIR"
            else
                print_fail "SAFETY: Test directory missing marker file, not deleting: $TEST_DIR"
            fi
        else
            print_fail "SAFETY: Test directory not in safe location, not deleting: $TEST_DIR"
        fi
    else
        log_info "Test directory preserved: ${TEST_DIR:-not created}"
    fi
}

# Note: trap will be set up after TEST_DIR is created for safety

# Create test directory with safety checks
setup_test_environment() {
    print_test "Setting up test environment"
    
    # Validate TMPDIR is safe
    local safe_tmp="${TMPDIR:-/tmp}"
    # Remove trailing slash if present
    safe_tmp="${safe_tmp%/}"
    
    # Ensure safe_tmp is actually a safe location
    case "$safe_tmp" in
        /tmp|/var/tmp|/private/tmp)
            ;; # These are OK
        *)
            # If TMPDIR is set to something else, validate it
            if [[ "$safe_tmp" =~ ^/home|^/Users|^/root|^/etc|^/usr|^/bin|^/sbin|^/opt ]]; then
                log_error "TMPDIR points to unsafe location: $safe_tmp"
                exit 1
            fi
            ;;
    esac
    
    # Create temp directory with more randomness
    TEST_DIR=$(mktemp -d "${safe_tmp}/git-cleanup-test.XXXXXX") || {
        print_fail "Failed to create temporary directory"
        exit 1
    }
    
    log_verbose "Created temp directory: $TEST_DIR"
    
    # Validate the created directory path
    case "$TEST_DIR" in
        /tmp/* | /var/tmp/* | /private/tmp/* | /var/folders/* )
            # Safe location (including macOS temp directories)
            ;;
        *)
            print_fail "Created directory is not in safe location: $TEST_DIR"
            safe_remove "$TEST_DIR"
            exit 1
            ;;
    esac
    
    # Create marker file for safety (atomically with directory)
    touch "$TEST_DIR/.git-cleanup-test-marker" || {
        print_fail "Failed to create safety marker"
        safe_remove "$TEST_DIR"
        exit 1
    }
    
    # Verify no symlinks in test directory
    if find "$TEST_DIR" -type l 2>/dev/null | grep -q .; then
        log_error "Test directory contains symlinks"
        safe_remove "$TEST_DIR"
        exit 1
    fi
    
    print_info "Created test directory: $TEST_DIR"
    
    # NOW set up trap for cleanup after TEST_DIR is properly set
    trap cleanup EXIT INT TERM
    
    # Verify cleanup script exists
    if [ ! -f "$CLEANUP_SCRIPT" ]; then
        print_fail "Cleanup script not found: $CLEANUP_SCRIPT"
        exit 1
    fi
    
    if [ ! -x "$CLEANUP_SCRIPT" ]; then
        print_info "Making cleanup script executable"
        chmod +x "$CLEANUP_SCRIPT"
    fi
    
    print_pass "Test environment setup complete"
}

# Create a test repository with various file types
create_test_repo() {
    local repo_name="$1"
    
    # Validate repo name doesn't contain dangerous characters
    if [[ "$repo_name" =~ \.\.|\/|\~ ]] || [[ "$repo_name" =~ ^\. ]]; then
        log_error "Invalid repository name: $repo_name"
        return 1
    fi
    
    local repo_path="$TEST_DIR/$repo_name"
    
    print_test "Creating test repository: $repo_name"
    
    # Validate path is safe
    if ! validate_safe_path "$repo_path" "Repository path"; then
        return 1
    fi
    
    mkdir -p "$repo_path"
    cd "$repo_path" || {
        print_fail "Failed to change to repository directory: $repo_path"
        return 1
    }
    
    # Initialize git repo
    git init
    git config user.email "test@example.com"
    git config user.name "Test User"
    
    # Create various files to test removal
    echo "# Test Repo" > README.md
    echo "Keep this file" > important.txt
    
    # Files to be removed
    mkdir -p test_data
    echo "Test data 1" > test_data/file1.txt
    echo "Test data 2" > test_data/file2.txt
    
    mkdir -p demo_files
    echo "Demo content" > demo_files/demo.txt
    
    echo "Secret password" > secrets.txt
    echo "API_KEY=12345" > .env
    
    # Create some log files
    echo "Log entry 1" > app.log
    echo "Log entry 2" > debug.log
    
    # Binary file
    dd if=/dev/zero of=large_file.bin bs=1024 count=10 2>/dev/null
    
    if [ "$VERBOSE" = true ]; then
        local file_size=$(get_file_size "large_file.bin")
        log_verbose "Created binary file: large_file.bin ($(human_readable_size "$file_size"))"
    fi
    
    # Commit initial files
    git add .
    git commit -m "Initial commit"
    
    # Make some more commits to create history
    echo "Updated content" >> important.txt
    git add important.txt
    git commit -m "Update important file"
    
    echo "More test data" > test_data/file3.txt
    git add test_data/file3.txt
    git commit -m "Add more test data"
    
    # Add remote (local bare repo)
    local remote_path="$TEST_DIR/${repo_name}.git"
    git init --bare "$remote_path"
    git remote add origin "$remote_path"
    git push -u origin main 2>/dev/null || git push -u origin master 2>/dev/null
    
    print_pass "Test repository created with $(git rev-list --count HEAD) commits"
    
    if [ "$VERBOSE" = true ]; then
        local repo_size=$(du -sh "$repo_path" 2>/dev/null | cut -f1)
        log_verbose "Repository size: $repo_size"
    fi
    
    cd "$TEST_DIR" || {
        print_fail "Failed to change to test directory"
        return 1
    }
}

# Test 1: Basic dry-run functionality
test_dry_run() {
    print_test "Testing dry-run functionality"
    
    local repo_path="$TEST_DIR/test-repo-1"
    create_test_repo "test-repo-1"
    
    # Create paths file with safety check
    local paths_file="$TEST_DIR/paths-to-remove.txt"
    
    # Validate paths file location
    if ! validate_safe_path "$paths_file" "Paths file"; then
        return 1
    fi
    
    # Ensure we're in test directory
    if [[ ! "$PWD" =~ /git-cleanup-test\. ]]; then
        print_fail "SAFETY: Not in test directory, aborting"
        return 1
    fi
    
    cat > "$paths_file" <<EOF
# Test paths file - ONLY for test repository
test_data/
demo_files/
secrets.txt
.env
*.log
large_file.bin
EOF
    
    cd "$repo_path" || {
        print_fail "Failed to change to repository directory: $repo_path"
        return 1
    }
    
    # Verify we're within the test directory hierarchy before running cleanup
    local current_dir
    current_dir=$(pwd -P)
    
    # Get canonical TEST_DIR for comparison
    local test_dir_canonical
    test_dir_canonical=$(cd "$TEST_DIR" 2>/dev/null && pwd -P)
    
    # Check if current directory is TEST_DIR or a subdirectory of it
    if [[ "$current_dir" != "$test_dir_canonical" ]] && 
       [[ "$current_dir" != "$test_dir_canonical"/* ]]; then
        print_fail "Not in test directory hierarchy, aborting for safety"
        log_verbose "Current: $current_dir"
        log_verbose "Test dir: $test_dir_canonical"
        return 1
    fi
    
    log_verbose "Safety check passed - in test directory hierarchy"
    
    # Run dry-run (with automatic acceptance of responsibility and branch warning)
    if { echo "I ACCEPT RESPONSIBILITY"; echo "rewrite-history"; } | "$CLEANUP_SCRIPT" . --permanently-remove-paths-from-file "$TEST_DIR/paths-to-remove.txt" --dry-run > "$TEST_DIR/dry-run.log" 2>&1; then
        print_pass "Dry-run completed successfully"
        
        # Verify no actual changes were made - ensure we're in the correct repo directory
        local current_pwd
        current_pwd=$(pwd -P)
        if [[ "$current_pwd" != "$repo_path" ]]; then
            log_verbose "Changing to repo directory for verification: $repo_path"
            cd "$repo_path" || {
                print_fail "Failed to change to repository for verification"
                return 1
            }
        fi
        
        # Check if test_data files are still in history (more robust check)
        local git_log_output
        git_log_output=$(git -C "$repo_path" log --all --name-status 2>/dev/null)
        if echo "$git_log_output" | grep -q "test_data"; then
            print_pass "Files still in history (dry-run didn't modify)"
        else
            print_fail "Files removed during dry-run!"
            if [ "$VERBOSE" = true ]; then
                log_verbose "Git log output for debugging:"
                echo "$git_log_output" | grep -i test || echo "No test_data files found in history"
                log_verbose "Full git log output:"
                echo "$git_log_output"
            fi
        fi
        
        # Check for backup creation skip
        if ! ls "${repo_path}.backup-"* 2>/dev/null >/dev/null; then
            print_pass "No backup created during dry-run"
        else
            print_fail "Backup created during dry-run"
        fi
    else
        print_fail "Dry-run failed"
        if [ "$VERBOSE" = true ]; then
            log_verbose "Dry-run output:"
            cat "$TEST_DIR/dry-run.log"
        fi
    fi
    
    cd "$TEST_DIR" || {
        print_fail "Failed to change to test directory"
        return 1
    }
}

# Test 2: Basic file removal
test_basic_removal() {
    print_test "Testing basic file removal"
    
    local repo_path="$TEST_DIR/test-repo-2"
    create_test_repo "test-repo-2"
    
    # Create simple paths file
    cat > "$TEST_DIR/simple-paths.txt" <<EOF
test_data/
secrets.txt
EOF
    
    log_verbose "Created paths file with $(grep -cv '^[[:space:]]*$' "$TEST_DIR/simple-paths.txt") entries"
    
    cd "$repo_path" || {
        print_fail "Failed to change to repository directory: $repo_path"
        return 1
    }
    
    # Get original commit count
    # Get original commit count for verification
    local original_commits
    original_commits=$(git rev-list --count HEAD)
    
    # Run actual cleanup (with automatic confirmations)
    # Need to provide all responses the script might ask for
    if { echo "I ACCEPT RESPONSIBILITY"; echo "rewrite-history"; echo "skip"; echo "REMOVE FILES FROM HISTORY"; echo "skip"; } | "$CLEANUP_SCRIPT" . --permanently-remove-paths-from-file "$TEST_DIR/simple-paths.txt" > "$TEST_DIR/removal.log" 2>&1; then
        print_pass "Cleanup completed successfully"
        
        # Ensure we're in the correct repo directory for verification
        local current_pwd
        current_pwd=$(pwd -P)
        if [[ "$current_pwd" != "$repo_path" ]]; then
            log_verbose "Changing to repo directory for verification: $repo_path"
            cd "$repo_path" || {
                print_fail "Failed to change to repository for verification"
                return 1
            }
        fi
        
        # Verify files were removed
        if ! git -C "$repo_path" log --all --name-status -- test_data 2>/dev/null | grep -q test_data; then
            print_pass "test_data/ successfully removed from history"
        else
            print_fail "test_data/ still in history"
        fi
        
        if ! git -C "$repo_path" log --all --name-status -- secrets.txt 2>/dev/null | grep -q secrets.txt; then
            print_pass "secrets.txt successfully removed from history"
        else
            print_fail "secrets.txt still in history"
        fi
        
        # Verify important files remain
        local important_git_log_output
        important_git_log_output=$(git -C "$repo_path" log --all --name-status 2>/dev/null)
        if echo "$important_git_log_output" | grep -q "important.txt"; then
            print_pass "important.txt preserved in history"
        else
            print_fail "important.txt was incorrectly removed"
            if [ "$VERBOSE" = true ]; then
                log_verbose "Git log output for debugging important.txt:"
                echo "$important_git_log_output" | grep -i important || echo "No important.txt found in history"
                log_verbose "Full git log output for important.txt debugging:"
                echo "$important_git_log_output"
                log_verbose "Current files in working directory:"
                ls -la "$repo_path" || echo "Cannot list repo directory"
                log_verbose "Contents of simple-paths.txt:"
                cat "$TEST_DIR/simple-paths.txt" || echo "Cannot read paths file"
            fi
        fi
        
        # Check backup exists
        if ls "${repo_path}.backup-"* >/dev/null 2>&1; then
            print_pass "Backup created successfully"
            if [ "$VERBOSE" = true ]; then
                local backup_dir=$(ls -d "${repo_path}.backup-"* | head -1)
                local backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
                log_verbose "Backup size: $backup_size"
            fi
        else
            print_fail "No backup found"
        fi
        
        # Check log file exists
        if ls "${repo_path}.cleanup-log-"*.log >/dev/null 2>&1; then
            print_pass "Log file created successfully"
            if [ "$VERBOSE" = true ]; then
                local log_file=$(ls "${repo_path}.cleanup-log-"*.log | head -1)
                local log_size=$(get_file_size "$log_file")
                log_verbose "Log file size: $(human_readable_size "$log_size")"
            fi
        else
            print_fail "No log file found"
        fi
        
    else
        print_fail "Cleanup failed"
        if [ "$VERBOSE" = true ]; then
            log_verbose "Removal output:"
            cat "$TEST_DIR/removal.log"
        fi
    fi
    
    cd "$TEST_DIR" || {
        print_fail "Failed to change to test directory"
        return 1
    }
}

# Test 3: Glob pattern removal
test_glob_patterns() {
    print_test "Testing glob pattern removal"
    
    local repo_path="$TEST_DIR/test-repo-3"
    create_test_repo "test-repo-3"
    
    # Create paths file with glob patterns (need glob: prefix)
    cat > "$TEST_DIR/glob-paths.txt" <<EOF
glob:*.log
glob:demo_*
EOF
    
    cd "$repo_path" || {
        print_fail "Failed to change to repository directory: $repo_path"
        return 1
    }
    
    # Run cleanup
    if { echo "I ACCEPT RESPONSIBILITY"; echo "rewrite-history"; echo "skip"; echo "REMOVE FILES FROM HISTORY"; echo "skip"; } | "$CLEANUP_SCRIPT" . --permanently-remove-paths-from-file "$TEST_DIR/glob-paths.txt" > "$TEST_DIR/glob.log" 2>&1; then
        print_pass "Glob pattern cleanup completed"
        
        # Ensure we're in the correct repo directory for verification
        local current_pwd
        current_pwd=$(pwd -P)
        if [[ "$current_pwd" != "$repo_path" ]]; then
            log_verbose "Changing to repo directory for verification: $repo_path"
            cd "$repo_path" || {
                print_fail "Failed to change to repository for verification"
                return 1
            }
        fi
        
        # Verify .log files were removed
        if ! git -C "$repo_path" log --all --name-status -- app.log 2>/dev/null | grep -q app.log; then
            print_pass "*.log pattern worked (app.log removed)"
        else
            print_fail "*.log pattern failed (app.log still present)"
        fi
        
        # Note: Simple verification may not catch all glob patterns
        # The script correctly skips complex pattern verification
        
    else
        print_fail "Glob pattern cleanup failed"
        if [ "$VERBOSE" = true ]; then
            log_verbose "Glob pattern output:"
            cat "$TEST_DIR/glob.log"
        fi
    fi
    
    cd "$TEST_DIR" || {
        print_fail "Failed to change to test directory"
        return 1
    }
}

# Test 4: Custom log file location
test_custom_log_file() {
    print_test "Testing custom log file location"
    
    local repo_path="$TEST_DIR/test-repo-4"
    create_test_repo "test-repo-4"
    
    local custom_log="$TEST_DIR/my-custom-cleanup.log"
    
    cat > "$TEST_DIR/minimal-paths.txt" <<EOF
large_file.bin
EOF
    
    cd "$repo_path" || {
        print_fail "Failed to change to repository directory: $repo_path"
        return 1
    }
    
    # Run with custom log file
    if { echo "I ACCEPT RESPONSIBILITY"; echo "rewrite-history"; echo "skip"; echo "REMOVE FILES FROM HISTORY"; echo "skip"; } | "$CLEANUP_SCRIPT" . --permanently-remove-paths-from-file "$TEST_DIR/minimal-paths.txt" --log-file "$custom_log" > /dev/null 2>&1; then
        
        if [ -f "$custom_log" ]; then
            print_pass "Custom log file created at specified location"
            if [ "$VERBOSE" = true ]; then
                local log_size=$(get_file_size "$custom_log")
                log_verbose "Custom log size: $(human_readable_size "$log_size")"
            fi
        else
            print_fail "Custom log file not found at: $custom_log"
        fi
        
        # Verify default log wasn't created
        if ! ls "${repo_path}.cleanup-log-"*.log >/dev/null 2>&1; then
            print_pass "Default log file correctly not created"
        else
            print_fail "Default log file created despite custom location"
        fi
        
    else
        print_fail "Cleanup with custom log failed"
    fi
    
    cd "$TEST_DIR" || {
        print_fail "Failed to change to test directory"
        return 1
    }
}

# Test 5: Error handling - missing paths file
test_missing_paths_file() {
    print_test "Testing error handling for missing paths file"
    
    local repo_path="$TEST_DIR/test-repo-5"
    create_test_repo "test-repo-5"
    
    cd "$repo_path" || {
        print_fail "Failed to change to repository directory: $repo_path"
        return 1
    }
    
    # Try to run with non-existent paths file (with automatic acceptance)
    if echo "I ACCEPT RESPONSIBILITY" | "$CLEANUP_SCRIPT" . --permanently-remove-paths-from-file "$TEST_DIR/nonexistent.txt" > "$TEST_DIR/error.log" 2>&1; then
        print_fail "Script succeeded with missing paths file (should have failed)"
    else
        print_pass "Script correctly failed with missing paths file"
        
        # Check for appropriate error message
        if grep -q "not found" "$TEST_DIR/error.log"; then
            print_pass "Appropriate error message for missing file"
        else
            print_fail "Error message doesn't mention missing file"
        fi
    fi
    
    cd "$TEST_DIR" || {
        print_fail "Failed to change to test directory"
        return 1
    }
}

# Test 6: Verification of removed files
test_verification_feature() {
    print_test "Testing built-in verification feature"
    
    local repo_path="$TEST_DIR/test-repo-6"
    create_test_repo "test-repo-6"
    
    cat > "$TEST_DIR/verify-paths.txt" <<EOF
test_data/file1.txt
test_data/file2.txt
demo_files/
EOF
    
    cd "$repo_path" || {
        print_fail "Failed to change to repository directory: $repo_path"
        return 1
    }
    
    # Run cleanup and capture output
    if { echo "I ACCEPT RESPONSIBILITY"; echo "rewrite-history"; echo "skip"; echo "REMOVE FILES FROM HISTORY"; echo "skip"; } | "$CLEANUP_SCRIPT" . --permanently-remove-paths-from-file "$TEST_DIR/verify-paths.txt" > "$TEST_DIR/verify.log" 2>&1; then
        
        # Check if verification ran
        if grep -q "Checking removal of files from paths file" "$TEST_DIR/verify.log"; then
            print_pass "Verification feature executed"
            
            # Check for success message
            if grep -q "successfully removed from history" "$TEST_DIR/verify.log"; then
                print_pass "Verification reported success"
            else
                print_fail "Verification didn't report success"
            fi
        else
            print_fail "Verification feature didn't run"
        fi
        
    else
        print_fail "Cleanup with verification failed"
    fi
    
    cd "$TEST_DIR" || {
        print_fail "Failed to change to test directory"
        return 1
    }
}

# Main test execution
main() {
    echo "Git History Cleanup Helper Test Suite"
    echo "====================================="
    echo ""
    
    # Show platform information
    log_verbose "Platform: $PLATFORM"
    log_verbose "Current directory: $PWD"
    
    # CRITICAL SAFETY CHECK: Never run in critical system directories
    if [[ "$PWD" =~ ^(/|/root|/etc|/usr|/bin|/sbin|/opt|/System|/Library)/?$ ]]; then
        log_error "FATAL: Test script cannot be run from system directory: $PWD"
        echo "Please run from a safe location"
        exit 1
    fi
    
    # Check prerequisites
    if ! command -v git >/dev/null 2>&1; then
        log_error "Git is not installed"
        exit 1
    fi
    
    if ! command -v git-filter-repo >/dev/null 2>&1; then
        log_error "git-filter-repo is not installed"
        echo "Please install git-filter-repo to run tests"
        exit 1
    fi
    
    log_verbose "Git version: $(git --version)"
    log_verbose "git-filter-repo version: $(git-filter-repo --version 2>/dev/null || echo 'unknown')"
    
    # Setup test environment
    setup_test_environment
    
    # Check disk space before tests
    if [ "$VERBOSE" = true ]; then
        local available_space=$(df -h "${TMPDIR:-/tmp}" 2>/dev/null | tail -1 | awk '{print $4}')
        log_verbose "Available temp space: $available_space"
    fi
    
    # Run tests
    test_dry_run
    test_basic_removal
    test_glob_patterns
    test_custom_log_file
    test_missing_paths_file
    test_verification_feature
    
    # Summary
    echo ""
    echo "Test Summary"
    echo "============"
    echo -e "${GREEN}Passed:${NC} $PASSED_TESTS"
    echo -e "${RED}Failed:${NC} $FAILED_TESTS"
    
    if [ "$VERBOSE" = true ] && [ -n "$TEST_DIR" ] && [ "$CLEANUP_AFTER" = false ]; then
        log_verbose "Test artifacts preserved in: $TEST_DIR"
    fi
    
    if [ "$FAILED_TESTS" -eq 0 ]; then
        log_success "All tests passed!"
        exit 0
    else
        log_error "Some tests failed!"
        exit 1
    fi
}

# Run main
main