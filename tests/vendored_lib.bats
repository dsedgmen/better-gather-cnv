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

@test "every script calling the library also sources it, directly or via common.sh" {
	cd "$SCRIPT_DIR"
	local missing=""
	for f in gather_*; do
		if grep -qE '\b(copy_pod_dir_since|pod_tar_dirs_since|filter_names_since|since_find_predicate|trim_jsonl_since|since_report|since_window_requested)\b' "$f"; then
			grep -qE 'since_common\.sh|common\.sh' "$f" || missing="$missing $f"
		fi
	done
	[ -z "$missing" ] || { echo "use the library but never source it:$missing" >&2; false; }
}

# =============================================================================
# The node audit.log filter
# =============================================================================
#
# Record shapes below are taken verbatim from a real
# /var/log/audit/audit.log on a 4.18 node, so the regex is pinned against
# what auditd actually writes rather than an invented sample.

audit_filter() {
	awk -v cutoff="$1" '{ if (match($0, /audit\([0-9]+\./)) { split(substr($0, RSTART + 6), a, "."); if (a[1] + 0 >= cutoff) print } else print }'
}

@test "audit filter keeps records at or after the cutoff and drops older ones" {
	run bash -c "
		$(declare -f audit_filter)
		printf '%s\n' \
			'type=DAEMON_START msg=audit(1788514794.021:2708): op=start ver=3.1.2 format=enriched' \
			'type=PROCTITLE msg=audit(1792198325.481:10059): proctitle=2F7573722F62696E2F6372756E' \
			| audit_filter 1792194828
	"
	assert_success
	assert_output --partial "1792198325"
	refute_output --partial "1788514794"
}

@test "audit filter is a no-op at cutoff 0" {
	run bash -c "
		$(declare -f audit_filter)
		printf '%s\n' \
			'type=DAEMON_START msg=audit(1788514794.021:2708): op=start' \
			'type=SERVICE_START msg=audit(1788514794.050:5): pid=1 uid=0' \
			| audit_filter 0 | wc -l
	"
	assert_success
	assert_output "2"
}

@test "audit filter passes lines with no audit timestamp through untouched" {
	# Real audit logs can carry non-record lines; dropping them silently
	# would be worse than collecting a little too much.
	run bash -c "
		$(declare -f audit_filter)
		printf '%s\n' 'some line with no stamp' 'type=X msg=audit(1700000000.1:1): old' \
			| audit_filter 1792194828
	"
	assert_success
	assert_output "some line with no stamp"
}

@test "audit filter uses only POSIX awk features" {
	# match() with a third argument is a gawk extension; the node pod is not
	# guaranteed to have gawk.
	run grep -c 'match($0, /audit\\([0-9]+\\./, ' "$SCRIPT_DIR/gather_nodes"
	assert_output "0"
	run bash -c "grep -c 'RSTART + 6' '$SCRIPT_DIR/gather_nodes'"
	assert_output "1"
}
