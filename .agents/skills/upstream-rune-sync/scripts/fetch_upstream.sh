#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SYNC_FILE="$REPO_ROOT/.upstream-sync.json"

UPSTREAM_DIR="${UPSTREAM_DIR:-/tmp/anomalyco-rune}"
UPSTREAM_EXPLICIT=0
DO_FETCH=1
BRANCH="main"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --upstream <dir>   Use an existing local clone (skips network clone/fetch by default)
  --fetch            Force 'git fetch origin' even when --upstream is provided
  --branch <name>    Upstream branch to compare against (default: main)
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream)
      UPSTREAM_DIR="$2"
      UPSTREAM_EXPLICIT=1
      DO_FETCH=0
      shift 2
      ;;
    --fetch)
      DO_FETCH=1
      shift
      ;;
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

UPSTREAM_REPO="https://github.com/anomalyco/rune"
SYNCED_COMMIT=""
SYNCED_DATE=""
SYNCED_SUBJECT=""

if [[ -f "$SYNC_FILE" ]]; then
  read -r UPSTREAM_REPO SYNCED_COMMIT SYNCED_DATE < <(
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("upstreamRepo", "https://github.com/anomalyco/rune"), d.get("syncedCommit", ""), d.get("syncedCommitDate", ""))
' "$SYNC_FILE"
  )
  SYNCED_SUBJECT="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("syncedCommitSubject", ""))' "$SYNC_FILE")"
fi

if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
  if [[ "$UPSTREAM_EXPLICIT" -eq 1 ]]; then
    echo "Error: --upstream directory is not a git repository: $UPSTREAM_DIR" >&2
    exit 1
  fi
  echo "Cloning $UPSTREAM_REPO into $UPSTREAM_DIR..."
  git clone --branch "$BRANCH" "$UPSTREAM_REPO" "$UPSTREAM_DIR"
elif [[ "$DO_FETCH" -eq 1 ]]; then
  echo "Fetching origin in $UPSTREAM_DIR..."
  git -C "$UPSTREAM_DIR" fetch --prune origin
  if git -C "$UPSTREAM_DIR" rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
    git -C "$UPSTREAM_DIR" merge --ff-only "origin/$BRANCH" >/dev/null 2>&1 || true
  fi
fi

HEAD_SHA="$(git -C "$UPSTREAM_DIR" rev-parse HEAD)"
HEAD_DATE="$(git -C "$UPSTREAM_DIR" log -1 --format=%cI HEAD)"
HEAD_SUBJECT="$(git -C "$UPSTREAM_DIR" log -1 --format=%s HEAD)"

echo "=== Upstream Sync Status ==="
echo "Upstream dir : $UPSTREAM_DIR"
echo "Upstream repo: $UPSTREAM_REPO"
echo "Upstream HEAD: $HEAD_SHA ($HEAD_DATE)"
echo "               $HEAD_SUBJECT"

if [[ -n "$SYNCED_COMMIT" ]]; then
  echo "Synced commit: $SYNCED_COMMIT ($SYNCED_DATE)"
  echo "               $SYNCED_SUBJECT"
  if [[ "$HEAD_SHA" == "$SYNCED_COMMIT" ]]; then
    echo "Status       : UP TO DATE (0 commits ahead)"
  elif git -C "$UPSTREAM_DIR" cat-file -e "${SYNCED_COMMIT}^{commit}" 2>/dev/null; then
    AHEAD_COUNT="$(git -C "$UPSTREAM_DIR" rev-list --count "${SYNCED_COMMIT}..HEAD")"
    echo "Status       : $AHEAD_COUNT commit(s) ahead of syncedCommit"
    if [[ "$AHEAD_COUNT" -gt 0 ]]; then
      echo ""
      echo "=== Recent Upstream Commits (${SYNCED_COMMIT:0:8}..HEAD) ==="
      git -C "$UPSTREAM_DIR" log --oneline -n 50 "${SYNCED_COMMIT}..HEAD"
      if [[ "$AHEAD_COUNT" -gt 50 ]]; then
        echo "... ($((AHEAD_COUNT - 50)) more commits)"
      fi
    fi
  else
    echo "Status       : WARNING - syncedCommit $SYNCED_COMMIT not found in upstream history"
  fi
else
  echo "Synced commit: (none — .upstream-sync.json missing)"
fi
