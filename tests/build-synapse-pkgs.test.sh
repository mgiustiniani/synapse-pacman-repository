#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$ROOT/build-synapse-pkgs.sh
TMP=$(mktemp -d /tmp/synapse-build-script-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

mkdir -p \
  "$TMP/pkgs/synapse-fixture" \
  "$TMP/pkgs/synapse-consumer" \
  "$TMP/pkgs/synapse-independent" \
  "$TMP/pkgs/synapse-failing" \
  "$TMP/pkgs/synapse-malformed" \
  "$TMP/bin" \
  "$TMP/repo"
cat >"$TMP/pkgs/synapse-fixture/PKGBUILD" <<'EOF'
pkgname=synapse-fixture
pkgver=1.0.0
pkgrel=1
pkgdesc='Rootless build-script fixture'
arch=('any')
license=('GPL-3.0-only')
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/synapse-fixture/fixture"
}
EOF
cat >"$TMP/pkgs/synapse-consumer/PKGBUILD" <<'EOF'
pkgname=synapse-consumer
pkgver=1.0.0
pkgrel=1
pkgdesc='Rootless selected-dependency bootstrap fixture'
arch=('any')
license=('GPL-3.0-only')
depends=('synapse-fixture>=1.0.0')
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/synapse-consumer/fixture"
}
EOF
cat >"$TMP/pkgs/synapse-independent/PKGBUILD" <<'EOF'
pkgname=synapse-independent
pkgver=1.0.0
pkgrel=1
pkgdesc='Independent partial-success fixture'
arch=('any')
license=('GPL-3.0-only')
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/synapse-independent/fixture"
}
EOF
cat >"$TMP/pkgs/synapse-failing/PKGBUILD" <<'EOF'
pkgname=synapse-failing
pkgver=1.0.0
pkgrel=1
pkgdesc='Expected build failure fixture'
arch=('any')
license=('GPL-3.0-only')
build() {
  return 23
}
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/synapse-failing/fixture"
}
EOF
cat >"$TMP/pkgs/synapse-malformed/PKGBUILD" <<'EOF'
pkgname=synapse-malformed
pkgver=1.0.0
pkgrel=1
pkgdesc='Expected metadata failure fixture'
arch=('any'
EOF
cat >"$TMP/bin/sudo" <<EOF
#!/usr/bin/env bash
touch "$TMP/sudo-called"
exit 97
EOF
chmod +x "$TMP/bin/sudo"

bash -n "$SCRIPT"
PATH="$TMP/bin:$PATH" SYNAPSE_REPO_DIR="$TMP/repo" \
  "$SCRIPT" --pkgbuilds-dir "$TMP/pkgs" \
  --package synapse-consumer --package synapse-fixture

[[ ! -e $TMP/sudo-called ]]
compgen -G "$TMP/repo/synapse-consumer-1.0.0-1-any.pkg.tar.zst" >/dev/null
compgen -G "$TMP/repo/synapse-fixture-1.0.0-1-any.pkg.tar.zst" >/dev/null
compgen -G "$TMP/repo/synapse-linux.db*" >/dev/null

SYNAPSE_REPO_DIR="$TMP/dry-repo" "$SCRIPT" \
  --pkgbuilds-dir "$TMP/pkgs" --package synapse-fixture --dry-run
[[ ! -e $TMP/dry-repo ]]

remove_preserved_build_dir() {
  local output=$1
  local preserved
  preserved=$(awk '/Package failure logs preserved:/{getline; gsub(/^[[:space:]]+/, ""); print; exit}' <<<"$output")
  if [[ $preserved == /tmp/synapse-build.* ]]; then
    rm -rf -- "$preserved"
  fi
}

# A malformed PKGBUILD and a build failure must not block an independent output.
set +e
partial_output=$(
  PATH="$TMP/bin:$PATH" SYNAPSE_REPO_DIR="$TMP/partial-repo" \
    "$SCRIPT" --pkgbuilds-dir "$TMP/pkgs" \
    --package synapse-independent \
    --package synapse-failing \
    --package synapse-malformed 2>&1
)
partial_rc=$?
set -e
printf '%s\n' "$partial_output"
((partial_rc == 0))
grep -Fq 'Partial success: independent successful packages were published.' \
  <<<"$partial_output"
compgen -G "$TMP/partial-repo/synapse-independent-1.0.0-1-any.pkg.tar.zst" >/dev/null
! compgen -G "$TMP/partial-repo/synapse-failing-*.pkg.tar.zst" >/dev/null
remove_preserved_build_dir "$partial_output"

# Strict mode still publishes the independent package but reports a failure.
set +e
strict_output=$(
  SYNAPSE_REPO_DIR="$TMP/strict-repo" "$SCRIPT" \
    --pkgbuilds-dir "$TMP/pkgs" \
    --package synapse-independent \
    --package synapse-failing \
    --strict 2>&1
)
strict_rc=$?
set -e
((strict_rc == 1))
compgen -G "$TMP/strict-repo/synapse-independent-1.0.0-1-any.pkg.tar.zst" >/dev/null
remove_preserved_build_dir "$strict_output"

# Oversized artifacts are excluded from both the output directory and repo DB.
set +e
size_output=$(
  SYNAPSE_MAX_PACKAGE_BYTES=1 SYNAPSE_REPO_DIR="$TMP/size-repo" \
    "$SCRIPT" --pkgbuilds-dir "$TMP/pkgs" \
    --package synapse-independent 2>&1
)
size_rc=$?
set -e
((size_rc == 1))
grep -Fq 'requires Git LFS or external storage' <<<"$size_output"
! compgen -G "$TMP/size-repo/*.pkg.tar.zst" >/dev/null
[[ ! -e $TMP/size-repo/synapse-linux.db ]]
remove_preserved_build_dir "$size_output"

if "$SCRIPT" --syncdeps --ignore-deps >/dev/null 2>&1; then
  echo 'mutually exclusive dependency options unexpectedly succeeded' >&2
  exit 1
fi
if SYNAPSE_MAX_PACKAGE_BYTES=invalid "$SCRIPT" --dry-run >/dev/null 2>&1; then
  echo 'invalid package size limit unexpectedly succeeded' >&2
  exit 1
fi

echo 'build-synapse-pkgs tests passed'
