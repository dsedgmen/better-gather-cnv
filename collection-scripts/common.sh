#!/bin/bash -x

DIR_NAME=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# duration_to_node_logs_since, get_since_cutoff and the helpers that apply the
# collection window to file-based collection. Vendored verbatim from
# dsedgmen/better-gather; update it there with hack/sync-since-lib.sh.
# shellcheck source=collection-scripts/since_common.sh
source "${DIR_NAME}/since_common.sh"
export BASE_COLLECTION_PATH="${BASE_COLLECTION_PATH:-/must-gather}"
export PROS=${PROS:-5}
export INSTALLATION_NAMESPACE=${INSTALLATION_NAMESPACE:-kubevirt-hyperconverged}

# Shared kernel red-flag grep pattern — used by gather_nodes and gather_vm_incident
export KERNEL_REDFLAG_PATTERN='nfs:|NFS |nfs |NFSERR|server not responding|zero writ|call_transmit|cb path stale|not responding for|qemu|QEMU|Out of memory|oom-kill|Killed process.*qemu|task .* blocked|blocked for more than|stuck for|jiffies'

function check_command {
    if [[ -z "$USR_BIN_GATHER" ]]; then
        echo "This script should not be directly executed." 1>&2
        echo "Please check \"${DIR_NAME}/gather --help\" for execution options." 1>&2
        exit 1
    fi
}

get_log_collection_args() {
	# validation of MUST_GATHER_SINCE and MUST_GATHER_SINCE_TIME is done by the
	# caller (oc adm must-gather) so it's safe to use the values as they are.
	log_collection_args=""

	if [ -n "${MUST_GATHER_SINCE:-}" ]; then
		log_collection_args=--since="${MUST_GATHER_SINCE}"
	fi
	if [ -n "${MUST_GATHER_SINCE_TIME:-}" ]; then
		log_collection_args=--since-time="${MUST_GATHER_SINCE_TIME}"
	fi

	# oc adm node-logs `--since` parameter is not the same as oc adm inspect `--since`.
	# it takes a simplified duration in the form of '(+|-)[0-9]+(s|m|h|d)' or
	# an ISO formatted time. since MUST_GATHER_SINCE and MUST_GATHER_SINCE_TIME
	# are formatted differently, we re-format them so they can be used
	# transparently by node-logs invocations.
	node_log_collection_args=""

	if [ -n "${MUST_GATHER_SINCE:-}" ]; then
		# node-logs accepts a single '(+|-)[0-9]+(s|m|h|d)' component, so a
		# multi-component duration has to be collapsed into one. Doing that
		# by keeping only the first component, as this did, silently narrows
		# the window: 2h30m becomes -2h and the oldest 30 minutes are never
		# collected, and 500ms becomes -500m, read as 500 minutes.
		since=$(duration_to_node_logs_since "${MUST_GATHER_SINCE}")
		node_log_collection_args=--since="-${since}"
	fi
	if [ -n "${MUST_GATHER_SINCE_TIME:-}" ]; then
	  # shellcheck disable=SC2001
		iso_time=$(echo "${MUST_GATHER_SINCE_TIME}" | sed 's/T/ /; s/Z//')
		node_log_collection_args=--since="${iso_time}"
	fi
	export log_collection_args
	export node_log_collection_args
}

query_prometheus() {
	local query="$1"
	local time="$2"
	local token
	local _xtrace
	_xtrace=$(shopt -po xtrace 2>/dev/null) || true
	{ set +x; } 2>/dev/null
	token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
	local result
	result=$(timeout 20 curl -ksg --connect-timeout 5 --max-time 15 -G \
		-H "Authorization: Bearer ${token}" \
		--data-urlencode "query=${query}" \
		--data-urlencode "time=${time}" \
		"https://thanos-querier.openshift-monitoring.svc:9091/api/v1/query" 2>/dev/null)
	echo "${result}"
	eval "$_xtrace"
}

query_prometheus_range() {
	local query="$1" start="$2" end="$3" step="${4:-30s}"
	local token
	local _xtrace
	_xtrace=$(shopt -po xtrace 2>/dev/null) || true
	{ set +x; } 2>/dev/null
	token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
	local result
	result=$(timeout 35 curl -ksg --connect-timeout 5 --max-time 30 -G \
		-H "Authorization: Bearer ${token}" \
		--data-urlencode "query=${query}" \
		--data-urlencode "start=${start}" \
		--data-urlencode "end=${end}" \
		--data-urlencode "step=${step}" \
		"https://thanos-querier.openshift-monitoring.svc:9091/api/v1/query_range" 2>/dev/null)
	echo "${result}"
	eval "$_xtrace"
}

# Collect virt-handler ghost record checkpoint files via a node-gather pod.
# Ghost records are on the host under /run/kubevirt-private/ghost-records; node-gather
# mounts host /run at /host/run.
# Args: <node_gather_pod> <dest_node_path>
collect_virt_handler_ghost_records() {
	local node_gather_pod="$1"
	local node_path="$2"
	local ghost_dir="/host/run/kubevirt-private/ghost-records"

	if ! timeout 10 /usr/bin/oc exec "${node_gather_pod}" -n node-gather -- \
		[ -d "${ghost_dir}" ] 2>/dev/null; then
		return 1
	fi

	mkdir -p "${node_path}/kubevirt-private"
	timeout 60 oc cp "${node_gather_pod}:${ghost_dir}/." "${node_path}/kubevirt-private/ghost-records/" \
		-n node-gather 2>/dev/null || true
}
