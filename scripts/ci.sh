#!/usr/bin/env bash
# Build and test every Swift package in this repo (one package per top-level folder).
#
# Usage: scripts/ci.sh [build|test|all] [Package ...]
#
#   build   swift build -c release for each package
#   test    swift test for each package that has a Tests/ directory
#   all     both (default)
#
# With no package names, every folder containing a Package.swift is processed, so new
# tools are picked up automatically. The script keeps going after a failure and reports
# everything at the end, so one broken package doesn't hide the others.
#
# Examples:
#   scripts/ci.sh
#   scripts/ci.sh test VoiceMemos
#   scripts/ci.sh build Mail Safari
set -euo pipefail

cd "$(dirname "$0")/.."

mode="all"
if [[ $# -gt 0 ]]; then
  mode="$1"
  shift
fi
case "$mode" in
  build | test | all) ;;
  *)
    echo "usage: scripts/ci.sh [build|test|all] [Package ...]" >&2
    exit 2
    ;;
esac

packages=()
if [[ $# -gt 0 ]]; then
  packages=("$@")
else
  for manifest in */Package.swift; do
    [[ -f "$manifest" ]] && packages+=("$(dirname "$manifest")")
  done
fi

group_start() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::group::$1"; else echo "==> $1"; fi
}
group_end() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::endgroup::"; fi
}

passed=()
failed=()

for pkg in ${packages[@]+"${packages[@]}"}; do
  pkg="${pkg%/}"
  if [[ ! -f "$pkg/Package.swift" ]]; then
    echo "error: no Package.swift in '$pkg'" >&2
    failed+=("$pkg (not a Swift package)")
    continue
  fi

  ok=1

  if [[ "$mode" == build || "$mode" == all ]]; then
    group_start "$pkg: build"
    if ! swift build -c release --package-path "$pkg"; then
      failed+=("$pkg: build")
      ok=0
    fi
    group_end
  fi

  # `swift test` fails for packages without tests, so skip those. A package whose build
  # just failed is skipped too, to avoid a second, redundant failure.
  if [[ "$mode" == test || "$mode" == all ]] && ((ok)); then
    if [[ -d "$pkg/Tests" ]]; then
      group_start "$pkg: test"
      if ! swift test --package-path "$pkg"; then
        failed+=("$pkg: test")
        ok=0
      fi
      group_end
    else
      echo "==> $pkg: no Tests directory, skipping tests"
    fi
  fi

  if ((ok)); then passed+=("$pkg"); fi
done

echo
echo "== Summary =="
if ((${#passed[@]})); then printf 'passed: %s\n' "${passed[@]}"; fi
if ((${#failed[@]})); then
  printf 'FAILED: %s\n' "${failed[@]}"
  exit 1
fi