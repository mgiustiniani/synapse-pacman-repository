#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_DIR=${SYNAPSE_REPO_DIR:-$ROOT/repo/x86_64}
MAX_PACKAGE_BYTES=${SYNAPSE_MAX_PACKAGE_BYTES:-104857600}
DB=$REPO_DIR/synapse-linux.db

[[ $MAX_PACKAGE_BYTES =~ ^[0-9]+$ ]]
[[ -f $DB ]]
for alias in synapse-linux.db.tar.gz synapse-linux.files synapse-linux.files.tar.gz; do
  [[ -f $REPO_DIR/$alias ]]
done

TMP=$(mktemp -d /tmp/synapse-repo-integrity.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
bsdtar -xf "$DB" -C "$TMP"

entries=0
for descriptor in "$TMP"/*/desc; do
  [[ -f $descriptor ]] || continue
  ((entries++)) || true
  filename=$(awk '/^%FILENAME%$/{getline; print; exit}' "$descriptor")
  expected_size=$(awk '/^%CSIZE%$/{getline; print; exit}' "$descriptor")
  expected_sha256=$(awk '/^%SHA256SUM%$/{getline; print; exit}' "$descriptor")
  package=$REPO_DIR/$filename

  [[ -n $filename && -f $package ]]
  actual_size=$(stat -c %s -- "$package")
  actual_sha256=$(sha256sum "$package" | awk '{print $1}')
  [[ $actual_size == "$expected_size" ]]
  [[ $actual_sha256 == "$expected_sha256" ]]
  ((MAX_PACKAGE_BYTES == 0 || actual_size <= MAX_PACKAGE_BYTES))
  bsdtar -tf "$package" >/dev/null

  if [[ ${SYNAPSE_REQUIRE_TRACKED:-false} == true ]]; then
    relative=${package#"$ROOT"/}
    git -C "$ROOT" ls-files --error-unmatch -- "$relative" >/dev/null
  fi
done

((entries > 0))

for removed in synapse-jdk25-graalvm-bin synapse-structurizr-onpremises; do
  ! grep -RqxF "$removed" "$TMP"/*/desc
  ! compgen -G "$REPO_DIR/$removed-*.pkg.tar.zst" >/dev/null
done

# Regression: legacy unowned binaries must not block an AXB35 package upgrade.
axb35_descriptor=$(grep -RlFx 'synapse-ec-su-axb35-linux' "$TMP"/*/desc | head -1)
[[ -n $axb35_descriptor ]]
axb35_filename=$(awk '/^%FILENAME%$/{getline; print; exit}' "$axb35_descriptor")
axb35_package=$REPO_DIR/$axb35_filename
! bsdtar -tf "$axb35_package" | grep -Eq '^usr/bin/axb35-(ctl|monitor)$'
for managed in usr/bin/synapse-axb35-ctl usr/bin/synapse-axb35-monitor; do
  bsdtar -tf "$axb35_package" | grep -qx "$managed"
done

printf 'repository integrity passed (%d package entries)\n' "$entries"
