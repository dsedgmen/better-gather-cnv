#!/bin/bash
# Common test helper, mirroring dsedgmen/better-gather including the offline
# fallback for bats-support/bats-assert, which no distribution packages.

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
export PROJECT_ROOT
SCRIPT_DIR="${PROJECT_ROOT}/collection-scripts"
export SCRIPT_DIR

BATS_ASSERT_AVAILABLE=1
for lib in bats-support bats-assert; do
	[[ -d "${PROJECT_ROOT}/tmp/bin/${lib}" ]] || BATS_ASSERT_AVAILABLE=0
done
export BATS_ASSERT_AVAILABLE

if [[ "${BATS_ASSERT_AVAILABLE}" -eq 1 ]]; then
	load "${PROJECT_ROOT}/tmp/bin/bats-support/load"
	load "${PROJECT_ROOT}/tmp/bin/bats-assert/load"
else
	load "${PROJECT_ROOT}/tests/bats_assert_fallback.bash"
fi

setup() {
	TEST_TMPDIR="$(mktemp -d)"
	export TEST_TMPDIR
	export BASE_COLLECTION_PATH="$TEST_TMPDIR/must-gather"
	mkdir -p "$BASE_COLLECTION_PATH"
}

teardown() {
	[[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
}
