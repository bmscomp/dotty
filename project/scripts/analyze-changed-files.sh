#!/usr/bin/env bash
#
# analyze-changed-files.sh
#
# Analyzes git changes to determine which test categories should run.
# Used by CI to enable test impact analysis - running only tests affected by changes.
#
# Usage:
#   ./project/scripts/analyze-changed-files.sh [--base-ref <ref>] [--dry-run]
#
# Output: JSON with test categories and whether to run full suite
#
# Example output:
# {
#   "run_full": false,
#   "categories": ["pos", "neg", "run"],
#   "changed_files_count": 5,
#   "matched_mappings": ["Parser", "Typer"]
# }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAPPING_FILE="$SCRIPT_DIR/test-impact-mapping.json"

# Default values
BASE_REF="${BASE_REF:-origin/main}"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --base-ref)
      BASE_REF="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--base-ref <ref>] [--dry-run]"
      echo ""
      echo "Options:"
      echo "  --base-ref <ref>  Base reference to compare against (default: origin/main)"
      echo "  --dry-run         Print debug info instead of JSON output"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Check if jq is available
if ! command -v jq &> /dev/null; then
  echo '{"run_full": true, "categories": [], "error": "jq not found"}'
  exit 0
fi

# Check if mapping file exists
if [[ ! -f "$MAPPING_FILE" ]]; then
  echo '{"run_full": true, "categories": [], "error": "mapping file not found"}'
  exit 0
fi

# Get changed files
cd "$PROJECT_ROOT"

# Handle GitHub Actions PR context
if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
  BASE_REF="origin/$GITHUB_BASE_REF"
fi

# Fetch base ref if needed (for CI)
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  git fetch origin "$GITHUB_BASE_REF" --depth=1 2>/dev/null || true
fi

# Get list of changed files
CHANGED_FILES=$(git diff --name-only "$BASE_REF"...HEAD 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null || echo "")

if [[ -z "$CHANGED_FILES" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "No changed files detected"
  fi
  echo '{"run_full": false, "categories": [], "changed_files_count": 0, "matched_mappings": []}'
  exit 0
fi

CHANGED_FILES_COUNT=$(echo "$CHANGED_FILES" | wc -l | tr -d ' ')

if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== Changed files ($CHANGED_FILES_COUNT) ==="
  echo "$CHANGED_FILES"
  echo ""
fi

# Check if any full suite trigger matches
FULL_SUITE_TRIGGERS=$(jq -r '.full_suite_triggers[]' "$MAPPING_FILE")
RUN_FULL=false

while IFS= read -r pattern; do
  # Convert glob pattern to regex for matching
  # Handle ** (match any path) and * (match single component)
  regex_pattern=$(echo "$pattern" | sed 's/\*\*/.*/' | sed 's/\*/[^\/]*/')

  while IFS= read -r file; do
    if [[ "$file" =~ ^$regex_pattern$ ]] || [[ "$file" == $pattern ]]; then
      RUN_FULL=true
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "Full suite trigger matched: $file (pattern: $pattern)"
      fi
      break 2
    fi
  done <<< "$CHANGED_FILES"
done <<< "$FULL_SUITE_TRIGGERS"

if [[ "$RUN_FULL" == "true" ]]; then
  echo "{\"run_full\": true, \"categories\": [], \"changed_files_count\": $CHANGED_FILES_COUNT, \"trigger\": \"full_suite_trigger_matched\"}"
  exit 0
fi

# Collect test categories from matching mappings
declare -A CATEGORIES=()
declare -a MATCHED_MAPPINGS=()

# Function to check if a file matches a glob pattern
# Uses bash's extended globbing
matches_pattern() {
  local file="$1"
  local pattern="$2"

  # Enable extended globbing
  shopt -s extglob

  # Convert ** to match any path and * to match any component
  # Using case statement with glob patterns
  case "$file" in
    $pattern) return 0 ;;
  esac

  return 1
}

MAPPING_COUNT=$(jq '.mappings | length' "$MAPPING_FILE")

for ((i=0; i<MAPPING_COUNT; i++)); do
  MAPPING_NAME=$(jq -r ".mappings[$i].name" "$MAPPING_FILE")
  PATTERNS=$(jq -r ".mappings[$i].source_patterns[]" "$MAPPING_FILE")

  MATCHED=false
  while IFS= read -r pattern; do
    # Convert glob ** to *  for simple matching (bash case supports * across /)
    simple_pattern="${pattern//\*\*/*}"

    while IFS= read -r file; do
      # Use case for glob matching
      case "$file" in
        $simple_pattern)
          MATCHED=true
          break 2
          ;;
      esac
    done <<< "$CHANGED_FILES"
  done <<< "$PATTERNS"

  if [[ "$MATCHED" == "true" ]]; then
    MATCHED_MAPPINGS+=("$MAPPING_NAME")

    # Add test categories from this mapping
    MAPPING_CATEGORIES=$(jq -r ".mappings[$i].test_categories[]" "$MAPPING_FILE")
    while IFS= read -r category; do
      CATEGORIES["$category"]=1
    done <<< "$MAPPING_CATEGORIES"

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "Matched mapping: $MAPPING_NAME"
      echo "  Categories: $MAPPING_CATEGORIES"
    fi
  fi
done

# Convert categories to JSON array
CATEGORIES_JSON="[]"
if [[ ${#CATEGORIES[@]} -gt 0 ]]; then
  CATEGORIES_JSON=$(printf '%s\n' "${!CATEGORIES[@]}" | jq -R . | jq -s .)
fi

# Convert matched mappings to JSON array
MAPPINGS_JSON="[]"
if [[ ${#MATCHED_MAPPINGS[@]} -gt 0 ]]; then
  MAPPINGS_JSON=$(printf '%s\n' "${MATCHED_MAPPINGS[@]}" | jq -R . | jq -s .)
fi

# If no categories matched, still don't run full suite (just run nothing extra)
# This handles documentation-only changes, etc.

if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "=== Result ==="
  echo "Run full suite: $RUN_FULL"
  if [[ ${#CATEGORIES[@]} -gt 0 ]]; then
    echo "Categories: ${!CATEGORIES[*]}"
  else
    echo "Categories: none"
  fi
  if [[ ${#MATCHED_MAPPINGS[@]} -gt 0 ]]; then
    echo "Matched mappings: ${MATCHED_MAPPINGS[*]}"
  else
    echo "Matched mappings: none"
  fi
fi

# Output JSON result
jq -n \
  --argjson run_full "$RUN_FULL" \
  --argjson categories "$CATEGORIES_JSON" \
  --argjson changed_files_count "$CHANGED_FILES_COUNT" \
  --argjson matched_mappings "$MAPPINGS_JSON" \
  '{
    run_full: $run_full,
    categories: $categories,
    changed_files_count: $changed_files_count,
    matched_mappings: $matched_mappings
  }'
