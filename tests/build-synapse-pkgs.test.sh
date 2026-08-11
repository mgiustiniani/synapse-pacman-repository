#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$ROOT/build-synapse-pkgs.sh
TMP=$(mktemp -d /tmp/synapse-build-script-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/pkgs/synapse-fixture" "$TMP/pkgs/synapse-consumer" "$TMP/bin" "$TMP/repo"
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

if "$SCRIPT" --syncdeps --ignore-deps >/dev/null 2>&1; then
  echo 'mutually exclusive dependency options unexpectedly succeeded' >&2
  exit 1
fi

echo 'build-synapse-pkgs tests passed'
