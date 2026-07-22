#!/bin/zsh

set -euo pipefail

swift test --enable-code-coverage

swift_bin_path="$(swift build --show-bin-path)"
test_binary="$swift_bin_path/MacControlPackageTests.xctest/Contents/MacOS/MacControlPackageTests"
profile="$swift_bin_path/codecov/default.profdata"
coverage_directory="$PWD/coverage"

if [[ ! -x "$test_binary" ]]; then
  print -u2 "Missing Swift test binary: $test_binary"
  exit 1
fi

if [[ ! -f "$profile" ]]; then
  print -u2 "Missing Swift coverage profile: $profile"
  exit 1
fi

mkdir -p "$coverage_directory"
xcrun llvm-cov export \
  -format=lcov \
  -instr-profile="$profile" \
  "$test_binary" \
  > "$coverage_directory/lcov.info"
