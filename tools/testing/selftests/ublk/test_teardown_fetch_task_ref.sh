#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# A canceled tag fetched again by another server task drops the old task.
#
# The steps of test_teardown_ready_count_takeover.sh, with the server in a
# cgroup of its own: thread 0 fetches tags 0 and 2 and closes its ring, then
# thread 1 fetches them again. A task_struct keeps its css_set, and so its
# cgroup, until the last put_task_struct(). A reference to thread 0 left in
# io->task keeps the removed cgroup dying, seen in nr_dying_descendants.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
CGROUP_ROOT=/sys/fs/cgroup

_prep_test "teardown" "canceled tags fetched again drop the old server task"

if ! _have_feature "PER_IO_DAEMON"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# tag states and the device state come only from debugfs
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# cgroup v2 only: the server cgroup must have no controllers
if ! grep -q "^nr_dying_descendants " "${CGROUP_ROOT}/cgroup.stat" 2> /dev/null; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi
PARENT_CG=${CGROUP_ROOT}/ublk_fetch_task_ref.$$
SERVER_CG=${PARENT_CG}/server
if ! mkdir "$PARENT_CG" "$SERVER_CG"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Usage: _tag_shows <dev_id> <word> <tag>
_tag_shows()
{
	awk -v tag="$3" '$1 == "tag" { in_tag = ($2 == tag) } in_tag' \
		"${DEBUGFS_ROOT}/$1/tags" 2> /dev/null | grep -q "$2"
}

# Usage: _wait_canceled <dev_id>
_wait_canceled()
{
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if _tag_shows "$1" CANCELED 0 && _tag_shows "$1" CANCELED 2; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

# rmdir fails while the server cgroup still has a task
_wait_server_cg_removed()
{
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if rmdir "$SERVER_CG" 2> /dev/null; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

_nr_dying()
{
	awk '$1 == "nr_dying_descendants" { print $2 }' "${PARENT_CG}/cgroup.stat"
}

_wait_server_cg_released()
{
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if [ "$(_nr_dying)" -eq 0 ]; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

# exec: the PID of the background job is then kublk itself
start_server()
{
	echo "$BASHPID" > "${SERVER_CG}/cgroup.procs" || exit 1
	exec "${UBLK_PROG}" add -n "$1" -t null -q 1 -d 4 --nthreads 2 \
		--per_io_tasks --exit_after_fetch --takeover_after_exit \
		--no_auto_part_scan --foreground
}

_stop_server()
{
	if ! _ublk_wait_daemon_gone "$daemon_pid" "$WAIT_SECS"; then
		ERR_CODE=255
	fi
	wait "$daemon_pid" > /dev/null 2>&1
	if ! _ublk_del_dev_timeout "$dev_id"; then
		ERR_CODE=255
	fi
}

# Usage: _end_test <message> <exit code>
_end_test()
{
	echo "$1"
	rmdir "$SERVER_CG" "$PARENT_CG" > /dev/null 2>&1
	if ! _check_dmesg; then
		echo "kernel complained"
		ERR_CODE=255
	fi
	if [ "$2" -ne 0 ]; then
		ERR_CODE=$2
	fi
	if [ "$ERR_CODE" -eq 0 ]; then
		echo "verdict: pass"
	else
		echo "verdict: fail"
	fi
	_cleanup_test
	_show_result $TID $ERR_CODE
}

dev_id=$(_ublk_find_free_id)
# no fd of ours: a server stuck in exit must not hold the caller's pipe open
start_server "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
daemon_pid=$!

if ! _wait_canceled "${dev_id}"; then
	_ublk_dump_dev_state "${dev_id}"
	_stop_server
	_end_test "closing thread 0's ring did not cancel tags 0 and 2" 255
fi

kill -USR2 "$daemon_pid"
if ! _ublk_wait_live "${dev_id}" "$WAIT_SECS"; then
	_ublk_dump_dev_state "${dev_id}"
	_stop_server
	_end_test "dev ${dev_id} did not go LIVE" 255
fi

_stop_server
if ! _wait_server_cg_removed; then
	_end_test "server cgroup still has a task after ${WAIT_SECS}s" 255
fi
if ! _wait_server_cg_released; then
	_end_test "server cgroup still pinned after ${WAIT_SECS}s: a task_struct reference leaked" 255
fi

_end_test "tags 0 and 2 fetched again, no server task left referenced" 0
