#!/usr/bin/env bash
#
# Create a detached clone of kubeflow/notebooks (not a fork)
# This preserves all commit history and branches for scorecard testing
#
# Usage: ./make-detached-notebooks-repo.sh --target-repo <YOUR_NEW_REPO_URL>
# Example: ./make-detached-notebooks-repo.sh --target-repo https://github.com/YOUR_USERNAME/notebooks-detached-clone.git

set -euo pipefail

# Configuration
upstream_repo="https://github.com/kubeflow/notebooks.git"
target_repo=""
temp_dir=$(mktemp -d)
branches=("main" "notebooks-v1" "notebooks-v2")
shallow_clone=false

# Colors for output
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
nc='\033[0m'

# Detect if terminal supports colors
use_colors=true
if [ ! -t 1 ] || [ "${NO_COLOR:-}" = "1" ]; then
    use_colors=false
fi

_log_info() {
    if [ "$use_colors" = "true" ]; then
        printf "${green}[INFO]${nc} %s\n" "$1"
    else
        printf "[INFO] %s\n" "$1"
    fi
}

_log_warn() {
    if [ "$use_colors" = "true" ]; then
        printf "${yellow}[WARN]${nc} %s\n" "$1" >&2
    else
        printf "[WARN] %s\n" "$1" >&2
    fi
}

_log_error() {
    if [ "$use_colors" = "true" ]; then
        printf "${red}[ERROR]${nc} %s\n" "$1" >&2
    else
        printf "[ERROR] %s\n" "$1" >&2
    fi
}

_cleanup() {
    if [ -n "$temp_dir" ] && [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir"
    fi
}

_usage() {
    cat <<EOF
Usage: $0 --target-repo <URL> [OPTIONS]

Create a detached clone of kubeflow/notebooks with full history.

PREREQUISITES:
  1. Create an EMPTY repository on GitHub first
     - Go to: https://github.com/new
     - Do NOT initialize with README, .gitignore, or license
     - Copy the repository URL

OPTIONS:
  --target-repo <URL>   URL of your new repository (required)
  --source-repo <URL>   URL of the source repository to clone
                        (default: https://github.com/kubeflow/notebooks.git)
  --branches <LIST>     Comma-separated list of branches to copy
                        (default: main,notebooks-v1,notebooks-v2)
  --shallow             Perform a shallow clone (depth 1, no history)
  --debug               Enable debug mode (set -x)
  -h, --help            Show this help message

EXAMPLES:
  $0 --target-repo https://github.com/YOUR_USERNAME/notebooks-test.git
  $0 --target-repo https://github.com/YOUR_USERNAME/notebooks-test.git --branches "main,develop,feature-x"

This script will:
  1. Clone the source repository with full history
  2. Rename 'origin' to 'upstream'
  3. Add your repo as 'origin'
  4. Push specified branches to your repo

NOTE: If your repo already has content, the script will automatically
      force push to overwrite it.
EOF
    exit 1
}

_check_env() {
    if ! command -v git >/dev/null 2>&1; then
        _log_error "git is not installed. Please install git first."
        exit 1
    fi
}

_validate_target_repo() {
    _log_info "Validating target repository is accessible..."
    if ! git ls-remote "$target_repo" &>/dev/null; then
        _log_error "Target repository is not accessible: $target_repo"
        _log_error "Please ensure the repository exists and you have access to it."
        exit 1
    fi
    _log_info "Target repository is accessible"
}

_validate_source_repo() {
    _log_info "Validating source repository is accessible..."
    if ! git ls-remote "$upstream_repo" &>/dev/null; then
        _log_error "Source repository is not accessible: $upstream_repo"
        _log_error "Please ensure the repository exists and you have access to it."
        exit 1
    fi
    _log_info "Source repository is accessible"
}

_parse_branches() {
    local input="$1"
    local -a parsed=()
    local old_ifs="$IFS"

    IFS=','
    for item in $input; do
        IFS="$old_ifs"
        # Trim leading and trailing whitespace
        item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$item" ]; then
            parsed+=("$item")
        fi
        IFS=','
    done
    IFS="$old_ifs"

    if [ ${#parsed[@]} -eq 0 ]; then
        _log_error "--branches requires at least one branch name"
        exit 1
    fi

    branches=("${parsed[@]}")
}

_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --target-repo)
                if [ $# -lt 2 ]; then
                    _log_error "--target-repo requires a value"
                    _usage
                fi
                target_repo="$2"
                shift 2
                ;;
            --target-repo=*)
                target_repo="${1#*=}"
                shift
                ;;
            --source-repo)
                if [ $# -lt 2 ]; then
                    _log_error "--source-repo requires a value"
                    _usage
                fi
                upstream_repo="$2"
                shift 2
                ;;
            --source-repo=*)
                upstream_repo="${1#*=}"
                shift
                ;;
            --branches)
                if [ $# -lt 2 ]; then
                    _log_error "--branches requires a value"
                    _usage
                fi
                _parse_branches "$2"
                shift 2
                ;;
            --branches=*)
                _parse_branches "${1#*=}"
                shift
                ;;
            --shallow)
                shallow_clone=true
                shift
                ;;
            --debug)
                trap 'set +x' EXIT
                set -x
                shift
                ;;
            -h|--help)
                _usage
                ;;
            *)
                _log_error "Unknown option: $1"
                _usage
                ;;
        esac
    done

    if [ -z "$target_repo" ]; then
        _log_error "--target-repo is required"
        _usage
    fi
}

_clone_upstream() {
    if [ "$shallow_clone" = "true" ]; then
        _log_info "Cloning $upstream_repo (shallow)..."
        git clone --depth 1 --no-single-branch "$upstream_repo" "$temp_dir"
    else
        _log_info "Cloning $upstream_repo..."
        git clone "$upstream_repo" "$temp_dir"
    fi
    cd "$temp_dir"
    _log_info "Successfully cloned upstream repository to $temp_dir"
}

_verify_branches() {
    _log_info "Verifying branches exist..."
    git fetch origin --prune

    for branch in "${branches[@]}"; do
        if git ls-remote --heads origin "$branch" | grep -q "$branch"; then
            _log_info "Branch '$branch' exists on remote"
        else
            _log_error "Branch '$branch' does not exist on remote"
            exit 1
        fi
    done
}

_setup_tracking_branches() {
    _log_info "Setting up local tracking branches..."

    for branch in "${branches[@]}"; do
        local current_branch
        current_branch=$(git branch --show-current)

        if [ "$current_branch" = "$branch" ]; then
            _log_info "Already on branch '$branch'"
        elif git show-ref --verify --quiet "refs/heads/$branch"; then
            git checkout "$branch"
            _log_info "Checked out existing local branch '$branch'"
        else
            git checkout -b "$branch" "origin/$branch"
            _log_info "Created and checked out new branch '$branch'"
        fi

        git pull origin "$branch"
    done
}

_reorganize_remotes() {
    _log_info "Reorganizing remotes (origin = yours, upstream = kubeflow)..."

    if git remote | grep -q "^upstream$"; then
        _log_info "'upstream' remote already exists"
    else
        git remote rename origin upstream
        _log_info "Renamed 'origin' to 'upstream'"
    fi

    if git remote | grep -q "^origin$"; then
        git remote set-url origin "$target_repo"
        _log_info "Updated 'origin' remote URL"
    else
        git remote add origin "$target_repo"
        _log_info "Added 'origin' remote: $target_repo"
    fi

    _log_info "Current remotes:"
    git remote -v
}

_push_branches() {
    _log_info "Pushing branches to your new repository..."

    for branch in "${branches[@]}"; do
        _log_info "Pushing branch: $branch"

        if ! git push -u origin "$branch" 2>/dev/null; then
            _log_warn "Normal push rejected, using force push to overwrite remote..."
            git push -u --force origin "$branch"
            _log_info "Force pushed branch '$branch' to origin"
        else
            _log_info "Pushed branch '$branch' to origin"
        fi
    done
}

_set_default_branch() {
    _log_info "Setting default branch to main..."
    git checkout main
}

_main() {
    trap _cleanup EXIT
    _parse_args "$@"
    _check_env
    _validate_source_repo
    _validate_target_repo
    _clone_upstream
    _verify_branches
    _setup_tracking_branches
    _reorganize_remotes
    _push_branches
    _set_default_branch

    _log_info "Setup complete! Your detached clone is ready at $target_repo"
}

_main "$@"
