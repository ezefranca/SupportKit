#!/bin/bash

set -euo pipefail

mode="${1:---all}"
case "$mode" in
  --all|--ci|--staged) ;;
  *)
    echo "Usage: $0 [--all|--ci|--staged]" >&2
    exit 64
    ;;
esac

required_tools=(swiftformat swiftlint jscpd rg)
for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 69
  fi
done

./scripts/check-secrets.sh

if [[ "$mode" == "--staged" ]]; then
  staged_files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] && staged_files+=("$file")
  done < <(git diff --cached --name-only --diff-filter=ACMR -- '*.swift')

  if [[ ${#staged_files[@]} -gt 0 ]]; then
    swiftformat "${staged_files[@]}" --lint
    swiftlint lint --strict "${staged_files[@]}"
  fi
  swift test
  exit 0
fi

swiftformat Sources Tests Package.swift --lint
swiftlint lint --strict
jscpd --no-tips Sources
git diff --check
swift package dump-package >/dev/null
swift build
swift build -c release
swift test
