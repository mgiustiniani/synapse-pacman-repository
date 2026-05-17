#!/usr/bin/env bash
# ================================================================
#  build-synapse-pkgs.sh
#  Clone CachyOS-PKGBUILDS @ cachyos-ai-integration,
#  build all packages whose pkgname starts with "synapse",
#  and install them into repo/x86_64/
# ================================================================
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────
PKGBUILDS_REPO="https://github.com/mgiustiniani/CachyOS-PKGBUILDS.git"
PKGBUILDS_BRANCH="cachyos-ai-integration"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)/repo/x86_64"
BUILD_DIR="$(mktemp -d /tmp/synapse-build.XXXXXX)"

# Parse args
DRY_RUN=false
CLEAN_UP=true
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --no-cleanup) CLEAN_UP=false ;;
  esac
done

EXIT_CODE=0

cleanup() {
  EXIT_CODE=$?
  if [[ -d "$BUILD_DIR" ]]; then
    if [[ $EXIT_CODE -ne 0 ]]; then
      echo ""
      echo "❌ Build fallito — directory di debug conservata:"
      echo "   $BUILD_DIR"
      echo "   I log sono in: $BUILD_DIR/*.build.log"
    elif $CLEAN_UP; then
      rm -rf "$BUILD_DIR"
      echo "[clean] removed $BUILD_DIR"
    fi
  fi
}
trap cleanup EXIT

echo "================================================================"
echo " synapse-pacman-repository — build script"
echo "================================================================"
echo " build dir : $BUILD_DIR"
echo " repo dir  : $REPO_DIR"
echo " dry run   : $DRY_RUN"
echo "================================================================"
echo ""

# ── Step 1: Clone PKGBUILDS ─────────────────────────────────────
echo "[1/4] Cloning CachyOS-PKGBUILDS @ $PKGBUILDS_BRANCH ..."
git clone --branch "$PKGBUILDS_BRANCH" --depth 1 --single-branch \
  "$PKGBUILDS_REPO" "$BUILD_DIR/pkgs" 2>&1
echo "[1/4] done."
echo ""

# ── Step 2: Find synapse* PKGBUILDs ─────────────────────────────
echo "[2/4] Finding PKGBUILDs with pkgname starting with 'synapse' ..."
SYNAPSE_DIRS=()

while IFS= read -r -d '' pkgbuild; do
  pkgdir=$(dirname "$pkgbuild")
  pkgname=$(grep -m1 '^pkgname=' "$pkgbuild" | cut -d= -f2 | tr -d "'\" ")
  if [[ "$pkgname" == synapse* ]]; then
    SYNAPSE_DIRS+=("$pkgdir")
    echo "  ✓ $(basename "$pkgdir") → $pkgname"
  fi
done < <(find "$BUILD_DIR/pkgs" -name PKGBUILD -print0)

if [[ ${#SYNAPSE_DIRS[@]} -eq 0 ]]; then
  echo "  ✗ No synapse* packages found. Exiting."
  exit 1
fi

echo "[2/4] found ${#SYNAPSE_DIRS[@]} package(s)."
echo ""

# ── Step 3: Build each package ─────────────────────────────────
echo "[3/4] Building packages ..."
FAILURES=()
SUCCESS=()

for pkgdir in "${SYNAPSE_DIRS[@]}"; do
  local_name=$(basename "$pkgdir")
  echo ""
  echo "  ┌─ Building: $local_name"
  echo "  ├─ dir: $pkgdir"

  if $DRY_RUN; then
    echo "  └─ [dry-run] would run: makepkg -s --noconfirm"
    SUCCESS+=("$local_name (dry-run)")
    continue
  fi

  # Build (set +e: non uscire al primo fallimento, continua con gli altri)
  set +e
  cd "$pkgdir"
  makepkg -s --noconfirm \
    > "$BUILD_DIR/${local_name}.build.log" 2>&1
  MAKEPKG_RC=$?
  cd -
  set -e

  if [[ $MAKEPKG_RC -eq 0 ]]; then
    echo "  └─ ✓ built successfully"
    SUCCESS+=("$local_name")
  else
    echo "  └─ ✗ build failed (exit $MAKEPKG_RC)"
    # Stampa ultime righe del log inline
    echo "     ── ultime 20 righe del log ──"
    tail -20 "$BUILD_DIR/${local_name}.build.log" 2>/dev/null | sed 's/^/     | /'
    echo "     ──────────────────────────────"
    echo "     Log completo: $BUILD_DIR/${local_name}.build.log"
    FAILURES+=("$local_name")
  fi
done

echo ""
echo "[3/4] Build summary: ${#SUCCESS[@]} ok, ${#FAILURES[@]} failed"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "  Failed: ${FAILURES[*]}"
  EXIT_CODE=1
fi
echo ""

# ── Step 4: Install into repo ──────────────────────────────────
echo "[4/4] Installing packages into repo ..."
mkdir -p "$REPO_DIR"

# Find all built .pkg.tar.zst files and copy them
PKG_COUNT=0
while IFS= read -r -d '' pkg; do
  cp "$pkg" "$REPO_DIR/"
  echo "  ✓ $(basename "$pkg")"
  ((PKG_COUNT++)) || true
done < <(find "$BUILD_DIR/pkgs" -name "*.pkg.tar.zst" -print0 2>/dev/null)

if [[ "$PKG_COUNT" -gt 0 || "$DRY_RUN" == "true" ]]; then
  # Update repo database
  if command -v repo-add &>/dev/null; then
    echo ""
    echo "  Updating repo database ..."
    repo-add --quiet "$REPO_DIR/synapse-linux.db" "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null \
      || repo-add --quiet "$REPO_DIR/synapse-linux.db.tar.gz" "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null \
      || echo "  ⚠ repo-add failed — database may be stale"
    echo "  ✓ database updated"
  else
    echo "  ⚠ repo-add not found — skipping database update"
    echo "    install it: pacman -S pacman-contrib"
  fi

  # Cleanup: remove .old files left by repo-add
  echo ""
  echo "  Cleaning up repo artifacts ..."
  rm -f "$REPO_DIR"/*.old
  echo "  ✓ removed .old files"

  # Convert symlinks to hardlinks (git hates symlinks to binary blobs)
  SYMLINK_COUNT=0
  for link in "$REPO_DIR"/*; do
    if [[ -L "$link" && -f "$link" ]]; then
      target=$(readlink "$link")
      if [[ -f "$target" ]]; then
        cp -l "$target" "$link" 2>/dev/null && ((SYMLINK_COUNT++)) || true
      fi
    fi
  done
  if [[ $SYMLINK_COUNT -gt 0 ]]; then
    echo "  ✓ converted $SYMLINK_COUNT symlink(s) to hardlink(s)"
  fi
fi

echo ""
echo "================================================================"
echo " Done!"
echo "================================================================"
