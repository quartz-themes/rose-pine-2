#!/usr/bin/env bash
#
# reset-to-v5.sh — Nuclear reset all quartz-themes preview repos to the v5 template
#
# Strategy:
#   1. Clone the template repo once as a bare reference
#   2. For each theme repo: fetch template tree, replace all files, apply per-repo overrides, force-push
#
# This completely replaces the repo contents with the template — no merge conflicts possible.
# GitHub Pages settings are stored in repo settings (not in the repo), so they survive force-push.
#
# Usage:
#   ./reset-to-v5.sh              # Reset all themes (with GNU parallel if available)
#   ./reset-to-v5.sh --dry-run    # Show what would happen without pushing
#   ./reset-to-v5.sh --jobs 8     # Override parallelism (default: 4)
#   ./reset-to-v5.sh theme1 ...   # Reset specific themes only
#
set -euo pipefail

# --- Configuration ---
TEMPLATE_REPO="https://github.com/quartz-themes/quartz-themes-preview-template.git"
TEMPLATE_BRANCH="v5"
TARGET_BRANCH="v5"
ORG="quartz-themes"
ENVIRONMENT_NAME="github-pages"
REPO_VISIBILITY="public"
DEFAULT_JOBS=4
DRY_RUN=false
JOBS="$DEFAULT_JOBS"
CREATE_MISSING=false

# --- Parse arguments ---
SPECIFIC_THEMES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run)
    DRY_RUN=true
    shift
    ;;
  --jobs)
    JOBS="$2"
    shift 2
    ;;
  -j)
    JOBS="$2"
    shift 2
    ;;
  -j*)
    JOBS="${1#-j}"
    shift
    ;;
  --create-missing)
    CREATE_MISSING=true
    shift
    ;;
  --help | -h)
    echo "Usage: $0 [--dry-run] [--jobs N] [theme1 theme2 ...]"
    echo ""
    echo "Options:"
    echo "  --dry-run         Show what would happen without pushing"
    echo "  --jobs N          Number of parallel workers (default: $DEFAULT_JOBS)"
    echo "  --create-missing  Create missing repos in ${ORG} if clone fails"
    echo "  theme1 ...        Reset only specific themes (default: all)"
    exit 0
    ;;
  *)
    SPECIFIC_THEMES+=("$1")
    shift
    ;;
  esac
done

NEED_GH=false
if [[ "$DRY_RUN" == "false" ]]; then
  NEED_GH=true
fi

if [[ "$NEED_GH" == "true" ]]; then
  if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI is required for environment/default-branch/branch-delete operations."
    exit 1
  fi
  if ! gh auth status -h github.com &>/dev/null; then
    echo "Error: gh CLI is not authenticated. Run 'gh auth login'."
    exit 1
  fi
fi

# --- Import all themes from theme-list ---
declare -a ALL_THEMES=(
  $(<theme-list)
)

# Use specific themes if provided, otherwise all
if [[ ${#SPECIFIC_THEMES[@]} -gt 0 ]]; then
  THEMES=("${SPECIFIC_THEMES[@]}")
else
  THEMES=("${ALL_THEMES[@]}")
fi

echo "=== Quartz Themes v5 Reset ==="
echo "Themes to reset: ${#THEMES[@]}"
echo "Target branch:   ${TARGET_BRANCH}"
echo "Parallel jobs:   ${JOBS}"
echo "Dry run:         ${DRY_RUN}"
echo ""

# --- Setup ---
WORK_DIR="$(mktemp -d)"
LOG_DIR="${WORK_DIR}/logs"
mkdir -p "$LOG_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Working directory: ${WORK_DIR}"

# Clone template once as a bare reference to get the tree object
echo "Fetching template ${TEMPLATE_BRANCH} branch..."
git clone --bare --single-branch -b "$TEMPLATE_BRANCH" "$TEMPLATE_REPO" "$WORK_DIR/template.git" 2>/dev/null
TEMPLATE_COMMIT=$(git -C "$WORK_DIR/template.git" rev-parse HEAD)
echo "Template commit: ${TEMPLATE_COMMIT}"
echo ""

# --- Worker function (called per theme, possibly in parallel) ---
reset_theme() {
  local theme="$1"
  local log_file="${LOG_DIR}/${theme}.log"

  {
    echo "--- START ${theme} ---"

    # Parse theme/variation from dotted name
    # e.g. "catppuccin.frappe" → THEME=catppuccin, VARIATION=frappe
    # e.g. "rose-pine" → THEME=rose-pine, VARIATION=null
    local IN="${theme}.null"
    local -a parts
    IFS='.' read -ra parts <<<"$IN"
    local THEME="${parts[0]}"
    local VARIATION="${parts[1]}"

    local repo_dir="${WORK_DIR}/repos/${theme}"

    if ! git clone --depth=1 "git@github.com:${ORG}/${theme}.git" "$repo_dir" -b "$TARGET_BRANCH" 2>/dev/null; then
      # v5 branch might not exist yet — clone whatever default branch, then create v5
      if ! git clone --depth=1 "git@github.com:${ORG}/${theme}.git" "$repo_dir" 2>/dev/null; then
        if [[ "$CREATE_MISSING" == "true" ]]; then
          if [[ "$DRY_RUN" == "true" ]]; then
            echo "DRY-RUN ${theme}: would create repo in ${ORG}"
            echo "--- END ${theme} (SKIP) ---"
            return 1
          fi
          if ! gh api -X POST "orgs/${ORG}/repos" -f name="$theme" -f visibility="$REPO_VISIBILITY" &>/dev/null; then
            echo "SKIP ${theme}: create failed"
            echo "--- END ${theme} (SKIP) ---"
            return 1
          fi
          if ! git clone --depth=1 "git@github.com:${ORG}/${theme}.git" "$repo_dir" 2>/dev/null; then
            echo "SKIP ${theme}: clone failed"
            echo "--- END ${theme} (SKIP) ---"
            return 1
          fi
        else
          echo "SKIP ${theme}: clone failed"
          echo "--- END ${theme} (SKIP) ---"
          return 1
        fi
      fi
    fi

    cd "$repo_dir"

    # Ensure we're on the target branch
    git checkout -B "$TARGET_BRANCH" 2>/dev/null

    # Fetch the template tree into this repo
    git remote add template "$TEMPLATE_REPO" 2>/dev/null || true
    git fetch --depth=1 template "$TEMPLATE_BRANCH" 2>/dev/null

    # Nuclear reset: replace the entire index with the template's tree
    local template_tree
    template_tree=$(git rev-parse "template/${TEMPLATE_BRANCH}^{tree}")
    git read-tree --reset -u "$template_tree"

    # Apply per-repo overrides to both config files
    for config_file in quartz.config.yaml quartz.config.default.yaml; do
      if [[ -f "$config_file" ]]; then
        sed -i "s|pageTitle: .*|pageTitle: ${theme}|" "$config_file"
        sed -i "s|baseUrl: .*|baseUrl: quartz-themes.github.io/${theme}|" "$config_file"
        sed -i "s|      theme: [a-zA-Z].*|      theme: ${THEME}|" "$config_file"
        sed -i "s|      variation: .*|      variation: ${VARIATION}|" "$config_file"
      fi
    done

    local updated=false

    # Stage everything
    git add -A

    # Check if there are actual changes to commit
    if git diff --cached --quiet 2>/dev/null; then
      updated=false
    else
      git -c user.name="quartz-themes-bot" -c user.email="bot@quartz-themes.github.io" \
        commit -m "Reset to v5 template ($(date -u +%Y-%m-%d))" --quiet

      if [[ "$DRY_RUN" == "true" ]]; then
        updated=true
      else
        git push origin "$TARGET_BRANCH" --force --quiet
        updated=true
      fi
    fi

    if [[ "$DRY_RUN" == "false" ]]; then
      local remote_heads
      if ! remote_heads=$(git ls-remote --heads origin "$TARGET_BRANCH" 2>/dev/null); then
        echo "SKIP ${theme}: unable to check remote branches"
        echo "--- END ${theme} (SKIP) ---"
        return 1
      fi
      if [[ -z "$remote_heads" ]]; then
        if ! git push origin "$TARGET_BRANCH" --quiet; then
          echo "SKIP ${theme}: failed to push ${TARGET_BRANCH}"
          echo "--- END ${theme} (SKIP) ---"
          return 1
        fi
      fi

      if ! gh api -X PUT "repos/${ORG}/${theme}/environments/${ENVIRONMENT_NAME}" \
        -F deployment_branch_policy[protected_branches]=false \
        -F deployment_branch_policy[custom_branch_policies]=true &>/dev/null; then
        echo "SKIP ${theme}: failed to update ${ENVIRONMENT_NAME} environment"
        echo "--- END ${theme} (SKIP) ---"
        return 1
      fi

      if ! gh api -X POST "repos/${ORG}/${theme}/environments/${ENVIRONMENT_NAME}/deployment-branch-policies" \
        -f type=branch -f name="${TARGET_BRANCH}" &>/dev/null; then
        gh api -X PUT "repos/${ORG}/${theme}/environments/${ENVIRONMENT_NAME}" \
          -F deployment_branch_policy[protected_branches]=false \
          -F deployment_branch_policy[custom_branch_policies]=false &>/dev/null || true
        echo "SKIP ${theme}: failed to add ${TARGET_BRANCH} branch policy"
        echo "--- END ${theme} (SKIP) ---"
        return 1
      fi

      if ! gh api -X PATCH "repos/${ORG}/${theme}" -f name="${theme}" -f default_branch="${TARGET_BRANCH}" &>/dev/null; then
        echo "SKIP ${theme}: failed to set default branch"
        echo "--- END ${theme} (SKIP) ---"
        return 1
      fi

      if ! gh api -X DELETE "repos/${ORG}/${theme}/git/refs/heads/v4" &>/dev/null; then
        echo "INFO ${theme}: v4 branch not deleted"
      fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      if [[ "$updated" == "true" ]]; then
        echo "DRY-RUN ${theme}: would force-push to ${TARGET_BRANCH}"
      else
        echo "DRY-RUN ${theme}: already up to date"
      fi
    else
      if [[ "$updated" == "true" ]]; then
        echo "OK ${theme}: reset and pushed"
      else
        echo "OK ${theme}: already up to date"
      fi
    fi

    # Cleanup Actions caches to prevent stale caches from breaking the CI after the reset
    if [[ "$DRY_RUN" == "false" ]]; then
      gh cache delete --repo "${ORG}/${theme}" --all 2>/dev/null || true
    fi

    # Cleanup
    cd "$WORK_DIR"
    rm -rf "$repo_dir"

    echo "--- END ${theme} ---"
  } >"$log_file" 2>&1

  # Print summary line to stdout
  local result
  result=$(grep -E "^(OK|SKIP|DRY-RUN)" "$log_file" | head -1)
  echo "$result"
}

export -f reset_theme
export WORK_DIR LOG_DIR TEMPLATE_REPO TEMPLATE_BRANCH TARGET_BRANCH DRY_RUN TEMPLATE_COMMIT ORG ENVIRONMENT_NAME CREATE_MISSING REPO_VISIBILITY

# --- Execute ---
FAILED=0
SUCCEEDED=0
SKIPPED=0
TOTAL=${#THEMES[@]}

if command -v parallel &>/dev/null && [[ "$JOBS" -gt 1 ]]; then
  echo "Using GNU parallel with ${JOBS} jobs..."
  echo ""
  printf '%s\n' "${THEMES[@]}" | parallel --jobs "$JOBS" --keep-order --line-buffer reset_theme {}
else
  if [[ "$JOBS" -gt 1 ]]; then
    echo "GNU parallel not found. Running sequentially..."
  else
    echo "Running sequentially..."
  fi
  echo ""

  for theme in "${THEMES[@]}"; do
    reset_theme "$theme" || true
  done
fi

# Count results from log files (avoids subshell counter issues)
for log in "$LOG_DIR"/*.log; do
  [[ -f "$log" ]] || continue
  if grep -q "^OK\|^DRY-RUN" "$log" 2>/dev/null; then
    ((SUCCEEDED++)) || true
  elif grep -q "^SKIP" "$log" 2>/dev/null; then
    ((SKIPPED++)) || true
  else
    ((FAILED++)) || true
  fi
done

echo ""
echo "=== Summary ==="
echo "Total:     ${TOTAL}"
echo "Succeeded: ${SUCCEEDED}"
echo "Skipped:   ${SKIPPED}"
echo "Failed:    $((TOTAL - SUCCEEDED - SKIPPED))"
echo ""

if [[ -d "$LOG_DIR" ]]; then
  for log in "$LOG_DIR"/*.log; do
    [[ -f "$log" ]] || continue
    if ! grep -q "^OK\|^DRY-RUN" "$log" 2>/dev/null; then
      theme_name=$(basename "$log" .log)
      echo "--- Failed: ${theme_name} ---"
      cat "$log"
      echo ""
    fi
  done
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "(Dry run — nothing was pushed)"
fi
