#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${BREW_BIN:-}" ]; then
    BREW_BIN="$BREW_BIN"
elif [ -x "/opt/homebrew/bin/brew" ]; then
    BREW_BIN="/opt/homebrew/bin/brew"
else
    BREW_BIN="$(command -v brew || true)"
fi
GH_BIN="${GH_BIN:-$(command -v gh || true)}"

APP_NAME="${APP_NAME:-Quitty}"
CASK_TOKEN="${CASK_TOKEN:-quitty}"
BUNDLE_ID="${BUNDLE_ID:-com.ct106.quitty}"
TAP_OWNER="${TAP_OWNER:-chentao1006}"
TAP_REPO="${TAP_REPO:-homebrew-tap}"
TAP_NAME="${TAP_NAME:-tap}"
SOURCE_REPO="${SOURCE_REPO:-chentao1006/quitty}"
DMG_ASSET_NAME="${DMG_ASSET_NAME:-Quitty.dmg}"
if [ -n "$BREW_BIN" ]; then
    HOMEBREW_REPO="$("$BREW_BIN" --repository 2>/dev/null || true)"
else
    HOMEBREW_REPO=""
fi
DEFAULT_TAP_DIR="${HOMEBREW_REPO}/Library/Taps/${TAP_OWNER}/homebrew-${TAP_NAME}"
if [ -z "$HOMEBREW_REPO" ]; then
    DEFAULT_TAP_DIR="${ROOT_DIR}/../${TAP_REPO}"
fi
TAP_DIR="${TAP_DIR:-$DEFAULT_TAP_DIR}"
RUN_BREW_STYLE="${RUN_BREW_STYLE:-1}"
RUN_BREW_AUDIT="${RUN_BREW_AUDIT:-0}"
SKIP_BREW_PUSH="${SKIP_BREW_PUSH:-0}"

usage() {
    cat <<EOF
Usage: $0 <dmg-path> <version>

Environment overrides:
  TAP_OWNER=$TAP_OWNER
  TAP_REPO=$TAP_REPO
  TAP_DIR=$TAP_DIR
  SOURCE_REPO=$SOURCE_REPO
  RUN_BREW_STYLE=0      Skip brew style
  RUN_BREW_AUDIT=1      Run brew audit after updating the tap
  SKIP_BREW_PUSH=1      Update and commit the tap without pushing
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

DMG_PATH="${1:-}"
VERSION="${2:-}"

if [ -z "$DMG_PATH" ] || [ -z "$VERSION" ]; then
    usage
    exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "Error: DMG not found: $DMG_PATH"
    exit 1
fi

if [ -z "$BREW_BIN" ]; then
    echo "Error: brew not found."
    exit 1
fi

TAG_NAME="v${VERSION}"
DOWNLOAD_URL="https://github.com/${SOURCE_REPO}/releases/download/${TAG_NAME}/${DMG_ASSET_NAME}"
SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
TAP_REMOTE="${TAP_REMOTE:-https://github.com/${TAP_OWNER}/${TAP_REPO}.git}"

echo "================================================="
echo "  Updating Homebrew tap"
echo "================================================="
echo "Version: $VERSION"
echo "DMG: $DMG_PATH"
echo "SHA256: $SHA256"
echo "Tap: ${TAP_OWNER}/${TAP_REPO}"

ensure_remote_repo() {
    if git ls-remote "$TAP_REMOTE" HEAD >/dev/null 2>&1; then
        return
    fi

    if [ -z "$GH_BIN" ]; then
        echo "Error: tap repository does not exist and gh is not installed."
        echo "Create https://github.com/${TAP_OWNER}/${TAP_REPO}, then rerun this script."
        exit 1
    fi

    if ! "$GH_BIN" auth status >/dev/null 2>&1; then
        echo "Error: GitHub CLI is not authenticated."
        echo "Run: gh auth login -h github.com"
        exit 1
    fi

    echo "Creating GitHub tap repository ${TAP_OWNER}/${TAP_REPO}..."
    "$GH_BIN" repo create "${TAP_OWNER}/${TAP_REPO}" \
        --public \
        --description "Homebrew tap for apps by ${TAP_OWNER}" \
        --clone=false
}

set_tap_origin() {
    if git -C "$TAP_DIR" remote get-url origin >/dev/null 2>&1; then
        git -C "$TAP_DIR" remote set-url origin "$TAP_REMOTE"
    else
        git -C "$TAP_DIR" remote add origin "$TAP_REMOTE"
    fi
}

ensure_tap_repo() {
    if [ -d "$TAP_DIR/.git" ]; then
        echo "Using existing tap checkout: $TAP_DIR"
        git -C "$TAP_DIR" checkout main || git -C "$TAP_DIR" checkout -B main
        if [ "$SKIP_BREW_PUSH" != "1" ]; then
            ensure_remote_repo
            set_tap_origin
            git -C "$TAP_DIR" fetch origin || true
            git -C "$TAP_DIR" pull --ff-only origin main || true
        fi
        return
    fi

    if git ls-remote "$TAP_REMOTE" HEAD >/dev/null 2>&1; then
        echo "Cloning tap repository to $TAP_DIR..."
        git clone "$TAP_REMOTE" "$TAP_DIR"
        return
    fi

    ensure_remote_repo
    git clone "$TAP_REMOTE" "$TAP_DIR"
}

ensure_local_brew_tap() {
    local current_tap_dir
    current_tap_dir="$("$BREW_BIN" --repo "${TAP_OWNER}/${TAP_NAME}" 2>/dev/null || true)"

    if [ "$current_tap_dir" = "$TAP_DIR" ]; then
        return
    fi

    if "$BREW_BIN" tap | grep -qx "${TAP_OWNER}/${TAP_NAME}"; then
        echo "Retapping ${TAP_OWNER}/${TAP_NAME} from $TAP_DIR..."
        "$BREW_BIN" untap "${TAP_OWNER}/${TAP_NAME}"
    fi

    echo "Registering local Homebrew tap ${TAP_OWNER}/${TAP_NAME}..."
    "$BREW_BIN" tap "${TAP_OWNER}/${TAP_NAME}" "$TAP_DIR"
}

write_tap_files() {
    mkdir -p "$TAP_DIR/Casks" "$TAP_DIR/.github/workflows"

    cat >"$TAP_DIR/Casks/${CASK_TOKEN}.rb" <<EOF
cask "$CASK_TOKEN" do
  version "$VERSION"
  sha256 "$SHA256"

  url "$DOWNLOAD_URL"
  name "$APP_NAME"
  desc "Quit apps automatically when their last window is closed"
  homepage "https://github.com/$SOURCE_REPO"

  depends_on macos: :big_sur

  app "$APP_NAME.app"

  zap trash: [
    "~/Library/Application Support/$APP_NAME",
    "~/Library/Caches/$BUNDLE_ID",
    "~/Library/HTTPStorages/$BUNDLE_ID",
    "~/Library/Preferences/$BUNDLE_ID.plist",
    "~/Library/Saved Application State/$BUNDLE_ID.savedState",
  ]
end
EOF

    cat >"$TAP_DIR/README.md" <<EOF
# Homebrew Tap

Shared Homebrew tap for apps by ${TAP_OWNER}.

## Available Casks

### Quitty

\`\`\`sh
brew install --cask ${TAP_OWNER}/${TAP_NAME}/${CASK_TOKEN}
\`\`\`

### Flux Monitor

\`\`\`sh
brew install --cask ${TAP_OWNER}/${TAP_NAME}/flux-monitor
\`\`\`

## Tap First

You can also tap the repository first, then install casks by token:

\`\`\`sh
brew tap ${TAP_OWNER}/${TAP_NAME}
brew install --cask ${CASK_TOKEN}
\`\`\`
EOF

    cat >"$TAP_DIR/.github/workflows/tests.yml" <<'EOF'
name: Tests

on:
  pull_request:
  push:
    branches:
      - main

jobs:
  test-bot:
    runs-on: macos-latest
    steps:
      - name: Set up Homebrew
        uses: Homebrew/actions/setup-homebrew@master
      - name: Test tap
        run: brew test-bot --only-cleanup-before --only-setup --only-tap-syntax
EOF
}

run_brew_checks() {
    if [ "$RUN_BREW_STYLE" != "1" ] && [ "$RUN_BREW_AUDIT" != "1" ]; then
        echo "Skipping brew checks because RUN_BREW_STYLE=$RUN_BREW_STYLE and RUN_BREW_AUDIT=$RUN_BREW_AUDIT."
        return
    fi

    ensure_local_brew_tap

    if [ "$RUN_BREW_STYLE" = "1" ]; then
        echo "Running brew style..."
        "$BREW_BIN" style --cask "${TAP_OWNER}/${TAP_NAME}/${CASK_TOKEN}"
    else
        echo "Skipping brew style because RUN_BREW_STYLE=$RUN_BREW_STYLE."
    fi

    if [ "$RUN_BREW_AUDIT" != "1" ]; then
        echo "Skipping brew audit because RUN_BREW_AUDIT=$RUN_BREW_AUDIT."
        return
    fi

    echo "Running brew audit..."
    if ! "$BREW_BIN" audit --cask --new "${TAP_OWNER}/${TAP_NAME}/${CASK_TOKEN}"; then
        echo "Warning: brew audit failed."
        echo "This commonly fails for private taps when the app is not notarized or the GitHub repo is below Homebrew/core notability thresholds."
        echo "Set RUN_BREW_AUDIT=0 to skip this check in release automation."
    fi
}

commit_and_push() {
    git -C "$TAP_DIR" add "Casks/${CASK_TOKEN}.rb" README.md .github/workflows/tests.yml

    if git -C "$TAP_DIR" diff --cached --quiet; then
        echo "No Homebrew tap changes to commit."
    else
        git -C "$TAP_DIR" commit -m "Update ${CASK_TOKEN} to ${VERSION}"
    fi

    if [ "$SKIP_BREW_PUSH" = "1" ]; then
        echo "Skipping tap push because SKIP_BREW_PUSH=1."
        return
    fi

    ensure_remote_repo
    set_tap_origin

    echo "Pushing tap repository..."
    git -C "$TAP_DIR" push origin main
}

ensure_tap_repo
write_tap_files
run_brew_checks
commit_and_push

echo "================================================="
echo "  Homebrew release updated"
echo "================================================="
echo "Install command: brew install --cask ${TAP_OWNER}/${TAP_NAME}/${CASK_TOKEN}"
