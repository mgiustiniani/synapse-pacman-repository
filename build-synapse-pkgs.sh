#!/usr/bin/env bash
# Build Synapse PKGBUILDs and publish their binary packages into repo/x86_64.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PKGBUILDS_REPO=${SYNAPSE_PKGBUILDS_REPO:-https://github.com/mgiustiniani/CachyOS-PKGBUILDS.git}
PKGBUILDS_BRANCH=${SYNAPSE_PKGBUILDS_BRANCH:-cachyos-ai-integration}
REPO_DIR=${SYNAPSE_REPO_DIR:-$SCRIPT_DIR/repo/x86_64}

DRY_RUN=false
CLEAN_UP=true
SYNC_DEPS=false
IGNORE_DEPS=false
STRICT=false
LOCAL_PKGBUILDS_DIR=
PACKAGE_FILTERS=()
BUILD_DIR=
EXIT_CODE=0
HAD_PACKAGE_FAILURES=false
MAX_PACKAGE_BYTES=${SYNAPSE_MAX_PACKAGE_BYTES:-104857600}

usage() {
  cat <<'EOF'
Usage: build-synapse-pkgs.sh [OPTIONS]

Builds matching synapse* PKGBUILDs without privilege escalation by default.
External dependencies must already be installed; dependencies selected in the
same run are bootstrapped locally. Use --syncdeps explicitly if makepkg should
ask the configured pacman authenticator to install missing dependencies.

Options:
  -p, --package NAME         Build only NAME (repeatable; directory or pkgname)
      --pkgbuilds-dir PATH   Use a local PKGBUILDs checkout instead of cloning
      --syncdeps             Pass --syncdeps to makepkg (may require authentication)
      --ignore-deps          Pass --nodeps to makepkg (unsafe; packaging/debug only)
      --dry-run              Discover and display builds without running makepkg
      --strict               Exit non-zero if any package fails
      --no-cleanup           Preserve the temporary log/clone directory on success
  -h, --help                 Show this help

By default, independent successful packages are published and the command exits
successfully even if another package fails. If no package can be published, the
command still fails. Use --strict when every selected package is mandatory.

Environment:
  SYNAPSE_PKGBUILDS_REPO     Git repository URL used when cloning
  SYNAPSE_PKGBUILDS_BRANCH   Git branch used when cloning
  SYNAPSE_REPO_DIR           Binary repository output directory
  SYNAPSE_MAX_PACKAGE_BYTES  Publication limit (default: 104857600; 0 disables)
EOF
}

require_value() {
  local option=$1
  local value=${2-}
  if [[ -z $value ]]; then
    echo "error: $option requires a value" >&2
    usage >&2
    exit 2
  fi
}

while (($#)); do
  case $1 in
    -p|--package)
      require_value "$1" "${2-}"
      PACKAGE_FILTERS+=("$2")
      shift 2
      ;;
    --package=*)
      require_value --package "${1#*=}"
      PACKAGE_FILTERS+=("${1#*=}")
      shift
      ;;
    --pkgbuilds-dir)
      require_value "$1" "${2-}"
      LOCAL_PKGBUILDS_DIR=$2
      shift 2
      ;;
    --pkgbuilds-dir=*)
      require_value --pkgbuilds-dir "${1#*=}"
      LOCAL_PKGBUILDS_DIR=${1#*=}
      shift
      ;;
    --syncdeps)
      SYNC_DEPS=true
      shift
      ;;
    --ignore-deps)
      IGNORE_DEPS=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --strict)
      STRICT=true
      shift
      ;;
    --no-cleanup)
      CLEAN_UP=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if $SYNC_DEPS && $IGNORE_DEPS; then
  echo 'error: --syncdeps and --ignore-deps are mutually exclusive' >&2
  exit 2
fi
if [[ ! $MAX_PACKAGE_BYTES =~ ^[0-9]+$ ]]; then
  echo 'error: SYNAPSE_MAX_PACKAGE_BYTES must be a non-negative integer' >&2
  exit 2
fi

if [[ -n $LOCAL_PKGBUILDS_DIR ]]; then
  if [[ ! -d $LOCAL_PKGBUILDS_DIR ]]; then
    echo "error: PKGBUILDs directory does not exist: $LOCAL_PKGBUILDS_DIR" >&2
    exit 2
  fi
  LOCAL_PKGBUILDS_DIR=$(realpath "$LOCAL_PKGBUILDS_DIR")
fi
REPO_DIR=$(realpath -m "$REPO_DIR")
BUILD_DIR=$(mktemp -d /tmp/synapse-build.XXXXXX)

cleanup() {
  local rc=$?
  if [[ -z $BUILD_DIR || ! -d $BUILD_DIR ]]; then
    return
  fi
  if ((rc != 0)) || $HAD_PACKAGE_FAILURES; then
    echo
    echo "Package failure logs preserved:"
    echo "  $BUILD_DIR"
    echo "  logs: $BUILD_DIR/*.build.log"
  elif $CLEAN_UP; then
    rm -rf "$BUILD_DIR"
    echo "[clean] removed $BUILD_DIR"
  else
    echo "[clean] preserved $BUILD_DIR (--no-cleanup)"
  fi
}
trap cleanup EXIT

if $SYNC_DEPS; then
  BUILD_MODE='sync missing dependencies (authentication may be required)'
elif $IGNORE_DEPS; then
  BUILD_MODE='ignore dependency checks'
else
  BUILD_MODE='rootless; installed dependencies only'
fi

printf '%s\n' '================================================================'
printf '%s\n' ' synapse-pacman-repository — build script'
printf '%s\n' '================================================================'
printf ' build dir : %s\n' "$BUILD_DIR"
printf ' repo dir  : %s\n' "$REPO_DIR"
printf ' mode      : %s\n' "$BUILD_MODE"
printf ' dry run   : %s\n' "$DRY_RUN"
printf '%s\n\n' '================================================================'

# Step 1: choose the PKGBUILDs source.
if [[ -n $LOCAL_PKGBUILDS_DIR ]]; then
  PKGBUILDS_ROOT=$LOCAL_PKGBUILDS_DIR
  echo "[1/4] Using local PKGBUILDs: $PKGBUILDS_ROOT"
else
  PKGBUILDS_ROOT=$BUILD_DIR/pkgs
  echo "[1/4] Cloning CachyOS-PKGBUILDS @ $PKGBUILDS_BRANCH ..."
  git clone --branch "$PKGBUILDS_BRANCH" --depth 1 --single-branch \
    "$PKGBUILDS_REPO" "$PKGBUILDS_ROOT" 2>&1
fi
echo '[1/4] done.'
echo

matches_filter() {
  local directory=$1
  local package=$2
  local filter
  ((${#PACKAGE_FILTERS[@]} == 0)) && return 0
  for filter in "${PACKAGE_FILTERS[@]}"; do
    if [[ $filter == "$directory" || $filter == "$package" ]]; then
      return 0
    fi
  done
  return 1
}

# Step 2: discover deterministic top-level and nested Synapse PKGBUILDs.
echo "[2/4] Finding PKGBUILDs with pkgname starting with 'synapse' ..."
SYNAPSE_DIRS=()
SYNAPSE_NAMES=()
declare -A FILTER_FOUND=()

while IFS= read -r -d '' pkgbuild; do
  pkgdir=$(dirname "$pkgbuild")
  local_name=$(basename "$pkgdir")
  pkgname=$(sed -n -E "/^[[:space:]]*pkgname=/{s/^[^=]+=//; s/[()'\"[:space:]]//g; p; q;}" "$pkgbuild")
  if [[ $pkgname != synapse* ]] || ! matches_filter "$local_name" "$pkgname"; then
    continue
  fi
  SYNAPSE_DIRS+=("$pkgdir")
  SYNAPSE_NAMES+=("$pkgname")
  echo "  ✓ $local_name → $pkgname"
  for filter in "${PACKAGE_FILTERS[@]}"; do
    if [[ $filter == "$local_name" || $filter == "$pkgname" ]]; then
      FILTER_FOUND["$filter"]=1
    fi
  done
done < <(
  find "$PKGBUILDS_ROOT" \
    \( -type d \( -name .git -o -name src -o -name pkg \) -prune \) -o \
    \( -type f -name PKGBUILD -print0 \) | sort -z
)

for filter in "${PACKAGE_FILTERS[@]}"; do
  if [[ -z ${FILTER_FOUND[$filter]+set} ]]; then
    echo "  ✗ requested package not found: $filter" >&2
    exit 1
  fi
done
if ((${#SYNAPSE_DIRS[@]} == 0)); then
  echo '  ✗ No matching synapse* packages found.' >&2
  exit 1
fi
printf '[2/4] found %d package(s).\n\n' "${#SYNAPSE_DIRS[@]}"

declare -A SELECTED_PACKAGE_NAMES=()
for pkgname in "${SYNAPSE_NAMES[@]}"; do
  SELECTED_PACKAGE_NAMES["$pkgname"]=1
done

dependency_name() {
  local dependency=$1
  printf '%s' "${dependency%%[<>=]*}"
}

# Resolve selected-package edges without allowing one malformed PKGBUILD to
# abort discovery for every other package.
FAILURES=()
declare -A DECLARED_DEPENDENCIES=() INTERNAL_DEPENDENCIES=()
declare -A FAILED_PACKAGE_NAMES=()
VALID_DIRS=()
VALID_NAMES=()
for index in "${!SYNAPSE_DIRS[@]}"; do
  pkgdir=${SYNAPSE_DIRS[$index]}
  pkgname=${SYNAPSE_NAMES[$index]}
  local_name=$(basename "$pkgdir")
  metadata_log=$BUILD_DIR/${local_name}.metadata.log
  if ! srcinfo=$(cd "$pkgdir" && makepkg --printsrcinfo 2>"$metadata_log"); then
    echo "  ✗ $local_name: invalid PKGBUILD metadata"
    tail -10 "$metadata_log" 2>/dev/null | sed 's/^/    | /'
    FAILURES+=("$local_name (metadata)")
    FAILED_PACKAGE_NAMES["$pkgname"]=1
    continue
  fi

  VALID_DIRS+=("$pkgdir")
  VALID_NAMES+=("$pkgname")
  dependencies=()
  mapfile -t dependencies < <(
    awk -F ' = ' -v arch=$(uname -m) '
      {
        key=$1
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        if (key == "depends" || key == "depends_" arch) print $2
      }
    ' <<<"$srcinfo"
  )
  DECLARED_DEPENDENCIES["$pkgname"]="${dependencies[*]}"
  internal=()
  for dependency in "${dependencies[@]}"; do
    name=$(dependency_name "$dependency")
    if [[ -n ${SELECTED_PACKAGE_NAMES[$name]+set} ]]; then
      internal+=("$name")
    fi
  done
  INTERNAL_DEPENDENCIES["$pkgname"]="${internal[*]}"
done
SYNAPSE_DIRS=("${VALID_DIRS[@]}")
SYNAPSE_NAMES=("${VALID_NAMES[@]}")

ORDERED_DIRS=()
ORDERED_NAMES=()
declare -A ORDERED_PACKAGE_NAMES=()
while ((${#ORDERED_NAMES[@]} < ${#SYNAPSE_NAMES[@]})); do
  progress=false
  for index in "${!SYNAPSE_NAMES[@]}"; do
    pkgname=${SYNAPSE_NAMES[$index]}
    [[ -z ${ORDERED_PACKAGE_NAMES[$pkgname]+set} ]] || continue
    ready=true
    for dependency in ${INTERNAL_DEPENDENCIES[$pkgname]-}; do
      if [[ -z ${ORDERED_PACKAGE_NAMES[$dependency]+set} \
          && -z ${FAILED_PACKAGE_NAMES[$dependency]+set} ]]; then
        ready=false
        break
      fi
    done
    $ready || continue
    ORDERED_DIRS+=("${SYNAPSE_DIRS[$index]}")
    ORDERED_NAMES+=("$pkgname")
    ORDERED_PACKAGE_NAMES["$pkgname"]=1
    progress=true
  done
  if ! $progress; then
    echo '  ⚠ selected package dependency cycle; preserving discovery order' >&2
    for index in "${!SYNAPSE_NAMES[@]}"; do
      pkgname=${SYNAPSE_NAMES[$index]}
      [[ -z ${ORDERED_PACKAGE_NAMES[$pkgname]+set} ]] || continue
      ORDERED_DIRS+=("${SYNAPSE_DIRS[$index]}")
      ORDERED_NAMES+=("$pkgname")
      ORDERED_PACKAGE_NAMES["$pkgname"]=1
    done
  fi
done
SYNAPSE_DIRS=("${ORDERED_DIRS[@]}")
SYNAPSE_NAMES=("${ORDERED_NAMES[@]}")

only_selected_dependencies_missing() {
  local pkgname=$1
  local dependency name
  local -a dependencies=() missing=()
  read -r -a dependencies <<<"${DECLARED_DEPENDENCIES[$pkgname]-}"
  ((${#dependencies[@]} > 0)) || return 1
  mapfile -t missing < <(pacman -T "${dependencies[@]}" 2>/dev/null || true)
  ((${#missing[@]} > 0)) || return 1
  for dependency in "${missing[@]}"; do
    name=$(dependency_name "$dependency")
    [[ -n ${SELECTED_PACKAGE_NAMES[$name]+set} ]] || return 1
  done
  return 0
}

# Step 3: build without --syncdeps unless the caller explicitly opted in.
echo '[3/4] Building packages ...'
SUCCESS=()
BUILT_PACKAGES=()
declare -A BUILT_SEEN=()
MAKEPKG_ARGS=(--noconfirm --force)
$SYNC_DEPS && MAKEPKG_ARGS+=(--syncdeps)
$IGNORE_DEPS && MAKEPKG_ARGS+=(--nodeps)

for index in "${!SYNAPSE_DIRS[@]}"; do
  pkgdir=${SYNAPSE_DIRS[$index]}
  pkgname=${SYNAPSE_NAMES[$index]}
  local_name=$(basename "$pkgdir")
  log=$BUILD_DIR/${local_name}.build.log
  blocked_by=()
  for dependency in ${INTERNAL_DEPENDENCIES[$pkgname]-}; do
    if [[ -n ${FAILED_PACKAGE_NAMES[$dependency]+set} ]]; then
      blocked_by+=("$dependency")
    fi
  done
  echo
  echo "  ┌─ Building: $local_name"
  echo "  ├─ pkgname: $pkgname"
  echo "  ├─ dir: $pkgdir"
  if ((${#blocked_by[@]} > 0)); then
    echo "  └─ ✗ skipped; selected dependency failed: ${blocked_by[*]}"
    FAILURES+=("$local_name")
    FAILED_PACKAGE_NAMES["$pkgname"]=1
    continue
  fi
  package_makepkg_args=("${MAKEPKG_ARGS[@]}")
  bootstrap_selected_dependency=false
  if ! $SYNC_DEPS && ! $IGNORE_DEPS && only_selected_dependencies_missing "$pkgname"; then
    package_makepkg_args+=(--nodeps)
    bootstrap_selected_dependency=true
  fi
  if $bootstrap_selected_dependency; then
    echo '  ├─ dependency mode: bootstrap selected local package(s)'
  fi

  if $DRY_RUN; then
    printf '  └─ [dry-run] would run: makepkg'
    printf ' %q' "${package_makepkg_args[@]}"
    printf '\n'
    SUCCESS+=("$local_name (dry-run)")
    continue
  fi

  set +e
  (cd "$pkgdir" && makepkg "${package_makepkg_args[@]}") >"$log" 2>&1
  makepkg_rc=$?
  set -e

  if ((makepkg_rc == 0)); then
    expected=()
    if ! packagelist=$(cd "$pkgdir" && makepkg --packagelist 2>>"$log"); then
      echo '  └─ ✗ unable to determine package output paths'
      FAILURES+=("$local_name")
      FAILED_PACKAGE_NAMES["$pkgname"]=1
      continue
    fi
    mapfile -t expected <<<"$packagelist"
    found_output=false
    for built_pkg in "${expected[@]}"; do
      if [[ -f $built_pkg && -z ${BUILT_SEEN[$built_pkg]+set} ]]; then
        BUILT_PACKAGES+=("$built_pkg")
        BUILT_SEEN["$built_pkg"]=1
        found_output=true
      fi
    done
    if $found_output; then
      echo '  └─ ✓ built successfully'
      SUCCESS+=("$local_name")
    else
      echo '  └─ ✗ makepkg returned success but produced no package'
      FAILURES+=("$local_name")
      FAILED_PACKAGE_NAMES["$pkgname"]=1
    fi
  else
    echo "  └─ ✗ build failed (exit $makepkg_rc)"
    echo '     ── last 20 log lines ──'
    tail -20 "$log" 2>/dev/null | sed 's/^/     | /'
    echo '     ───────────────────────'
    echo "     full log: $log"
    FAILURES+=("$local_name")
    FAILED_PACKAGE_NAMES["$pkgname"]=1
  fi
done

echo
printf '[3/4] Build summary: %d ok, %d failed\n' "${#SUCCESS[@]}" "${#FAILURES[@]}"
if ((${#FAILURES[@]} > 0)); then
  echo "  Failed: ${FAILURES[*]}"
  HAD_PACKAGE_FAILURES=true
fi
echo

# Step 4: publish each successful output independently. Package filenames are
# immutable: changing bytes requires a pkgver/pkgrel bump. GitHub rejects normal
# Git blobs larger than 100 MiB, so oversized artifacts are never added to the
# Pacman database unless an operator explicitly changes the configured limit.
echo '[4/4] Installing packages into repo ...'
PUBLISHED_PACKAGES=()
PUBLISH_FAILURES=()
if $DRY_RUN; then
  echo '  [dry-run] no package outputs or repository changes'
elif ((${#BUILT_PACKAGES[@]} == 0)); then
  echo '  No successful package outputs to publish.'
else
  mkdir -p "$REPO_DIR"
  if ! command -v repo-add >/dev/null 2>&1; then
    echo '  ✗ repo-add not found; install pacman-contrib' >&2
    EXIT_CODE=1
  else
    for pkg in "${BUILT_PACKAGES[@]}"; do
      filename=$(basename "$pkg")
      destination=$REPO_DIR/$filename
      package_size=$(stat -c %s -- "$pkg")

      if ((MAX_PACKAGE_BYTES > 0 && package_size > MAX_PACKAGE_BYTES)); then
        echo "  ✗ $filename"
        echo "    package is $package_size bytes; limit is $MAX_PACKAGE_BYTES"
        echo '    not published: this artifact requires Git LFS or external storage'
        PUBLISH_FAILURES+=("$filename (oversized)")
        HAD_PACKAGE_FAILURES=true
        continue
      fi

      copied=false
      if [[ -e $destination ]]; then
        if ! cmp -s -- "$pkg" "$destination"; then
          echo "  ✗ $filename"
          echo '    immutable package filename already exists with different content'
          echo '    bump pkgrel or pkgver before rebuilding'
          PUBLISH_FAILURES+=("$filename (version not bumped)")
          HAD_PACKAGE_FAILURES=true
          continue
        fi
        echo "  ✓ $filename (already present, unchanged)"
      else
        temporary=$REPO_DIR/.${filename}.tmp.$$
        if ! cp -- "$pkg" "$temporary" || ! mv -- "$temporary" "$destination"; then
          rm -f -- "$temporary"
          echo "  ✗ unable to copy $filename" >&2
          PUBLISH_FAILURES+=("$filename (copy failed)")
          HAD_PACKAGE_FAILURES=true
          continue
        fi
        copied=true
        echo "  ✓ $filename"
      fi

      # Update one package at a time so a bad artifact cannot block independent
      # packages from reaching the repository database.
      if repo-add --quiet "$REPO_DIR/synapse-linux.db.tar.gz" "$destination"; then
        PUBLISHED_PACKAGES+=("$filename")
      else
        echo "  ✗ repo-add failed for $filename" >&2
        PUBLISH_FAILURES+=("$filename (repo-add failed)")
        HAD_PACKAGE_FAILURES=true
        if $copied; then
          rm -f -- "$destination"
        fi
      fi
    done

    if ((${#PUBLISHED_PACKAGES[@]} > 0)); then
      echo
      printf '  ✓ database updated for %d package(s)\n' "${#PUBLISHED_PACKAGES[@]}"
      echo '  Cleaning up repo artifacts ...'
      rm -f -- "$REPO_DIR"/*.old
      echo '  ✓ removed .old files'

      shopt -s nullglob
      symlink_count=0
      for link in "$REPO_DIR"/*; do
        [[ -L $link && -f $link ]] || continue
        target=$(readlink -- "$link")
        if [[ $target = /* ]]; then
          target_path=$target
        else
          target_path=$REPO_DIR/$target
        fi
        if [[ -f $target_path ]]; then
          rm -- "$link"
          cp -l -- "$target_path" "$link"
          ((symlink_count++)) || true
        fi
      done
      shopt -u nullglob
      if ((symlink_count > 0)); then
        echo "  ✓ converted $symlink_count symlink(s) to hardlink(s)"
      fi
    else
      echo '  No package outputs were publishable.'
    fi
  fi
fi

PACKAGE_FAILURE_COUNT=$((${#FAILURES[@]} + ${#PUBLISH_FAILURES[@]}))
if ((PACKAGE_FAILURE_COUNT > 0)); then
  HAD_PACKAGE_FAILURES=true
  if $STRICT || { ! $DRY_RUN && ((${#PUBLISHED_PACKAGES[@]} == 0)); }; then
    EXIT_CODE=1
  elif ! $DRY_RUN; then
    echo
    echo '  Partial success: independent successful packages were published.'
    echo '  Re-run with --strict to make any package failure fatal.'
  fi
fi

echo
printf '%s\n' '================================================================'
if ((EXIT_CODE != 0)); then
  echo ' Completed with failures.'
elif ((PACKAGE_FAILURE_COUNT > 0)); then
  echo ' Completed with package failures (partial success).'
else
  echo ' Done!'
fi
printf '%s\n' '================================================================'
exit "$EXIT_CODE"
