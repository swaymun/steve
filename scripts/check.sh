#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cd "$repo_dir"
swift test --package-path native
swift build --package-path native --configuration release
