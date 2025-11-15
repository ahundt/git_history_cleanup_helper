#!/usr/bin/env bash

# A Universal Git Fixer CLI
# Corrects author history and modernizes commit signing with a focus on safety,
# idempotency, and adherence to Universal System Design Philosophy.

set -e -o pipefail -u

# --- Communication Principles: Use clear, colored output ---
print_info() { echo -e "\n\033[1;34m$1\033[0m"; }
print_success() { echo -e "\033[1;32m$1\033[0m"; }
print_warning() { echo -e "\033[1;31m$1\033[0m"; }
print_dim() { echo -e "\033[2m$1\033[0m"; }

# --- Script Variables and Defaults ---
CORRECT_NAME=""
CORRECT_EMAIL=""
OLD_EMAIL=""
ACTION_SETUP_SIGNING=false
NON_INTERACTIVE=false

show_help() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo
    echo "A tool to correct Git author history and optionally set up GPG signing."
    echo
    echo "Options:"
    echo "  --name <name>         Your correct full name."
    echo "  --email <email>       Your correct email address (must be on GitHub for GPG)."
    echo "  --old-email <email>   The incorrect email address to replace in the commit history."
    echo "  --setup-signing       Optional. Find or generate a GPG key and configure Git for signing."
    echo "  --non-interactive     Run without confirmation prompts. Use with caution."
    echo "  --help                Show this help message."
    echo
    echo "Example:"
    echo "  $(basename "$0") --name \"My Name\" --email \"me@example.com\" --old-email \"test@example.com\" --setup-signing"
}

# --- Core Logic Functions ---

check_prerequisites() {
    print_info "🔍 Checking prerequisites..."
    
    # Check if we're in a git repository
    if ! git rev-parse --is-inside-work-tree &> /dev/null; then
        print_warning "❌ This script must be run from within a Git repository."
        exit 1
    fi
    
    # Check for required commands
    local missing_commands=()
    
    if ! command -v git &> /dev/null; then
        missing_commands+=("git")
    fi
    
    if ! command -v gpg &> /dev/null; then
        missing_commands+=("gpg")
    fi
    
    if ! command -v gh &> /dev/null; then
        missing_commands+=("gh (GitHub CLI)")
    fi
    
    if ! command -v git-filter-repo &> /dev/null; then
        missing_commands+=("git-filter-repo")
    fi
    
    if [ ${#missing_commands[@]} -gt 0 ]; then
        print_warning "❌ Missing required commands: ${missing_commands[*]}"
        print_info "Please install the missing commands and try again."
        exit 1
    fi
    
    # Check GitHub CLI authentication
    if [[ "$ACTION_SETUP_SIGNING" = true ]]; then
        if ! gh auth status &> /dev/null; then
            print_warning "❌ GitHub CLI is not authenticated. Please run 'gh auth login' first."
            exit 1
        fi
    fi
    
    print_success "✅ All prerequisites met."
}

gather_info_interactive() {
    print_info "📝 Gathering identity information interactively..."
    local detected_name
    detected_name=$(git config --global user.name || echo "")
    local detected_email
    detected_email=$(git config --global user.email || echo "")
    
    if [ -z "$CORRECT_NAME" ]; then
        read -p "Enter your correct full name [${detected_name}]: " name_input
        CORRECT_NAME=${name_input:-$detected_name}
    fi
    if [ -z "$CORRECT_EMAIL" ]; then
        read -p "Enter your correct email [${detected_email}]: " email_input
        CORRECT_EMAIL=${email_input:-$detected_email}
    fi
    if [ -z "$OLD_EMAIL" ]; then
        # Handle empty repos gracefully
        if git rev-list -n 1 --all > /dev/null 2>&1; then
            local detected_old_email
            detected_old_email=$(git log --all --pretty=format:"%ae" | grep -v "${CORRECT_EMAIL}" | sort | uniq -c | sort -nr | head -n 1 | awk '{print $2}' || echo "")
            read -p "Enter the incorrect email to replace [${detected_old_email}]: " old_email_input
            OLD_EMAIL=${old_email_input:-$detected_old_email}
        else
            print_info "   (Skipping old email prompt in this empty repository)"
        fi
    fi
}

setup_gpg_signing() {
    print_info "🔑 Modernizing repository with GPG commit signing..."
    
    # Get GPG keys for the email
    local gpg_keys_output
    gpg_keys_output=$(gpg --list-secret-keys --keyid-format=long "${CORRECT_EMAIL}" 2>/dev/null | grep 'sec' || echo "")
    
    local gpg_key_id=""
    
    if [ -z "$gpg_keys_output" ]; then
        print_warning "⚠️ No GPG key found for ${CORRECT_EMAIL}. Generating a new one..."
        if ! gpg --full-generate-key; then
            print_warning "❌ Failed to generate GPG key."
            exit 1
        fi
        gpg_key_id=$(gpg --list-secret-keys --keyid-format=long "${CORRECT_EMAIL}" 2>/dev/null | grep 'sec' | head -n1 | awk '{print $2}' | cut -d'/' -f2)
    else
        local key_count
        key_count=$(echo "$gpg_keys_output" | wc -l | tr -d ' ')
        
        if [ "$key_count" -eq 1 ]; then
            gpg_key_id=$(echo "$gpg_keys_output" | awk '{print $2}' | cut -d'/' -f2)
            print_success "✅ Found a single existing GPG key: $gpg_key_id"
        else
            print_warning "⚠️ Found multiple GPG keys for ${CORRECT_EMAIL}. Please choose one:"
            # Create an array of key IDs for selection
            local -a key_ids
            while IFS= read -r line; do
                key_ids+=("$(echo "$line" | awk '{print $2}' | cut -d'/' -f2)")
            done <<< "$gpg_keys_output"
            
            PS3="Please select a key (1-${#key_ids[@]}): "
            select key_choice in "${key_ids[@]}"; do
                if [ -n "$key_choice" ]; then
                    gpg_key_id="$key_choice"
                    break
                fi
            done < /dev/tty
        fi
    fi
    
    if [ -z "$gpg_key_id" ]; then
        print_warning "❌ Failed to determine GPG key ID."
        exit 1
    fi
    
    # Upload key to GitHub if not already present
    if gh gpg-key list 2>/dev/null | grep -q "$gpg_key_id"; then
        print_success "✅ GPG key ($gpg_key_id) is already linked to your GitHub account."
    else
        print_info "   Uploading GPG key to GitHub..."
        if ! gpg --armor --export "$gpg_key_id" | gh gpg-key add -; then
            print_warning "❌ Failed to upload GPG key to GitHub."
            exit 1
        fi
    fi

    git config --local user.signingkey "$gpg_key_id"
    git config --local commit.gpgsign true
    print_success "✅ Git is now configured to sign commits for this repository (locally)."
}

rewrite_history() {
    if [ -z "$OLD_EMAIL" ]; then
        print_info "⏩ No '--old-email' provided. Skipping history rewrite."
        return
    fi
    
    # Check if repository has any commits
    if ! git rev-list --all --count &> /dev/null || [ "$(git rev-list --all --count)" -eq 0 ]; then
        print_success "✅ Repository is empty. History rewrite is not needed."
        return
    fi

    # Auto-detect the remote name
    local remote_name
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    remote_name=$(git config --get "branch.${current_branch}.remote" 2>/dev/null || echo "origin")
    
    # Verify remote exists
    if ! git remote get-url "$remote_name" &>/dev/null; then
        print_warning "⚠️ Remote '$remote_name' not found. Using 'origin' as fallback."
        remote_name="origin"
        if ! git remote get-url "$remote_name" &>/dev/null; then
            print_warning "❌ No remote found. Cannot push changes."
            exit 1
        fi
    fi
    
    print_info "🔄 Rewriting history to replace '${OLD_EMAIL}' with '${CORRECT_EMAIL}'..."
    
    # Create a backup tag before rewriting
    local backup_tag="backup-$(date +%Y%m%d-%H%M%S)"
    print_info "   Creating backup tag: $backup_tag"
    git tag "$backup_tag"
    
    # Confirm with user unless in non-interactive mode
    if [[ "$NON_INTERACTIVE" = false ]]; then
        print_warning "⚠️ WARNING: This will rewrite Git history. This is irreversible!"
        print_info "   A backup tag '$backup_tag' has been created."
        read -p "Type 'REWRITE' to confirm: " confirm
        if [[ "$confirm" != "REWRITE" ]]; then
            print_info "   Aborted by user."
            git tag -d "$backup_tag"
            exit 0
        fi
    fi
    
    # Use git-filter-repo to rewrite history
    local filter_cmd="
if email == b'${OLD_EMAIL}':
    name = b'${CORRECT_NAME}'
    email = b'${CORRECT_EMAIL}'
"
    
    if ! git filter-repo --force --commit-callback "
$filter_cmd
commit.author_name = name if commit.author_email == b'${OLD_EMAIL}' else commit.author_name
commit.author_email = email if commit.author_email == b'${OLD_EMAIL}' else commit.author_email
commit.committer_name = name if commit.committer_email == b'${OLD_EMAIL}' else commit.committer_name  
commit.committer_email = email if commit.committer_email == b'${OLD_EMAIL}' else commit.committer_email
"; then
        print_warning "❌ History rewrite failed. Restoring from backup..."
        git reset --hard "$backup_tag"
        git tag -d "$backup_tag"
        exit 1
    fi
    
    print_success "✅ History rewritten successfully."
    
    # Push the corrected history
    if [[ "$NON_INTERACTIVE" = false ]]; then
        print_warning "⚠️ About to force-push rewritten history to '$remote_name'."
        read -p "Type 'PUSH' to confirm: " confirm
        if [[ "$confirm" != "PUSH" ]]; then
            print_info "   Push cancelled by user. Local history has been rewritten."
            print_info "   You can push manually later with: git push --force-with-lease $remote_name --all"
            return
        fi
    fi
    
    print_info "🚀 Pushing corrected history to remote '$remote_name'..."
    if ! git push --force-with-lease "$remote_name" --all; then
        print_warning "❌ Failed to push branches. Please check remote permissions."
        exit 1
    fi
    
    if ! git push --force-with-lease "$remote_name" --tags; then
        print_warning "⚠️ Failed to push tags, but branches were updated successfully."
    fi
    
    print_success "✅ History corrected and pushed successfully."
    print_info "   Backup tag '$backup_tag' is available if needed."
}

# --- Main Execution ---
if [[ $# -eq 0 ]]; then
    show_help
    # Entering interactive mode because no flags were passed
    NON_INTERACTIVE=false
else
    # Parse CLI arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) 
                if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                    print_warning "❌ --name requires a value"
                    exit 1
                fi
                CORRECT_NAME="$2"; shift 2;;
            --email) 
                if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                    print_warning "❌ --email requires a value"
                    exit 1
                fi
                CORRECT_EMAIL="$2"; shift 2;;
            --old-email) 
                if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                    print_warning "❌ --old-email requires a value"
                    exit 1
                fi
                OLD_EMAIL="$2"; shift 2;;
            --setup-signing) ACTION_SETUP_SIGNING=true; shift 1;;
            --non-interactive) NON_INTERACTIVE=true; shift 1;;
            --help) show_help; exit 0;;
            *) print_warning "Unknown option: $1"; show_help; exit 1;;
        esac
    done
fi

check_prerequisites

# Validate email format
validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        print_warning "❌ Invalid email format: $email"
        exit 1
    fi
}

if [[ "$NON_INTERACTIVE" = false ]] && [[ -z "$CORRECT_NAME" || -z "$CORRECT_EMAIL" ]]; then
    gather_info_interactive
fi

if [[ -z "$CORRECT_NAME" || -z "$CORRECT_EMAIL" ]]; then
    print_warning "❌ Correct name and email are required. Use --name and --email flags."
    exit 1
fi

# Validate emails
if [[ -n "$CORRECT_EMAIL" ]]; then
    validate_email "$CORRECT_EMAIL"
fi
if [[ -n "$OLD_EMAIL" ]]; then
    validate_email "$OLD_EMAIL"
fi

# Execute planned actions
if [[ "$ACTION_SETUP_SIGNING" = true ]]; then
    setup_gpg_signing
fi

rewrite_history # This function now internally checks if it needs to run

print_info "🎉 Process complete."