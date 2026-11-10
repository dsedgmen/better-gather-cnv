#!/usr/bin/env bats
# The vendored since_common.sh must stay identical to the canonical copy in
# dsedgmen/better-gather, and the CNV-specific wiring must stay in place.

load test_helper

@test "vendored since_common.sh is self-contained" {
	run grep -E '^\s*(source|\.)\s' "$SCRIPT_DIR/since_common.sh"
	refute_output --partial "common.sh"
}

@test "vendored since_common.sh matches the canonical copy if it is checked out" {
	canonical="${PROJECT_ROOT}/../better-gather/collection-scripts/since_common.sh"
	[ -f "$canonical" ] || skip "better-gather is not checked out alongside this repo"
	run cmp -s "$canonical" "$SCRIPT_DIR/since_common.sh"
	assert_success
}

@test "common.sh sources the library and uses the exact duration collapse" {
	# one source line, plus the shellcheck directive above it
	run bash -c "grep -c '^source .*since_common.sh' '$SCRIPT_DIR/common.sh'"
	assert_success
	assert_output "1"
	# the call site, ignoring the mention in the header comment
	run bash -c "grep -c 'since=\$(duration_to_node_logs_since' '$SCRIPT_DIR/common.sh'"
	assert_output "1"
}

@test "common.sh no longer truncates a duration to its first component" {
	run grep -c 's/\\([0-9]\*\[dhms\]\\).\*/\\1/' "$SCRIPT_DIR/common.sh"
	assert_output "0"
}

@test "duration collapse is exact for CNV's node-logs journal queries" {
	run bash -c "
		source \"$SCRIPT_DIR/since_common.sh\"
		echo \"\$(duration_to_node_logs_since 2h30m0s) \$(duration_to_node_logs_since 500ms) \$(duration_to_node_logs_since 1h0m30s)\"
	"
	assert_success
	assert_output "150m 1s 3630s"
}

@test "QEMU log collection is bounded by the window" {
	# count invocations, not the mentions in comments
	for f in gather_vms_details gather_vm_incident; do
		run bash -c "grep -c '\\\$(since_find_predicate)' '$SCRIPT_DIR/$f'"
		assert_success
		assert_output "1"
	done
}

@test "node audit.log is filtered by auditd epoch, and capped from the end" {
	run grep -c "RSTART + 6" "$SCRIPT_DIR/gather_nodes"
	assert_output "1"
	# head -c on audit.log would keep the oldest 50MB
	run bash -c "grep 'audit.log' '$SCRIPT_DIR/gather_nodes' | grep -c 'head -c'"
	assert_output "0"
}

# The 'sources the library' guard now lives in the vendored since_common.bats,
# which accepts either a direct source or one through common.sh.
