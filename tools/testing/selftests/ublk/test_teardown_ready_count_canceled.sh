#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# A queue must not count as ready while some of its tags hold no command.
#
# Two server threads share one queue with --per_io_tasks. Thread 0 fetches
# tags 0 and 2 and closes its ring, which cancels both commands. On SIGUSR2
# thread 1 fetches tags 1 and 3. Tags 0 and 2 hold no command, so the queue
# must stay at nr_io_ready 2 and the device must not go LIVE.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
READY_SECS=$((5 * UBLK_WAIT_SCALE))

_prep_test "teardown" "queue not ready while canceled tags hold no command"

if ! _have_feature "PER_IO_DAEMON"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# tag states and nr_io_ready come only from debugfs
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Return 0 once the queue counts every tag ready or the device is LIVE.
_wait_queue_ready()
{
	local dev_id=$1
	local secs=0

	while [ "$secs" -lt "$READY_SECS" ]; do
		if [ "$(_ublk_nr_io_ready "$dev_id")" = 4 ]; then
			return 0
		fi
		if grep -q "^state: LIVE$" "${DEBUGFS_ROOT}/${dev_id}/dev_state"; then
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
	exec "${UBLK_PROG}" add -n "$1" -t null -q 1 -d 4 --nthreads 2 \
		--per_io_tasks --exit_after_fetch --no_auto_part_scan --foreground
}

# START_DEV of a queue that never gets ready waits until SIGKILL.
# Usage: _end_test <message> <exit code>
_end_test()
{
	echo "$1"
	kill -9 "$daemon_pid"
	if ! _ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"; then
		echo "kublk did not exit within ${WAIT_SECS}s"
		ERR_CODE=255
	fi
	if ! _ublk_del_dev_timeout "$dev_id"; then
		ERR_CODE=255
	fi
	if ! _check_dmesg; then
		echo "kernel complained while deleting the device"
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

dev_id=$(_ublk_free_dev_id)
# no fd of ours: a server stuck in exit must not hold the caller's pipe open
start_server "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
daemon_pid=$!

if ! _ublk_wait_tags_show "${dev_id}" CANCELED "$WAIT_SECS" 0 2; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "closing thread 0's ring did not cancel tags 0 and 2" 255
fi

kill -USR2 "$daemon_pid"
if ! _ublk_wait_tags_show "${dev_id}" CMD_PARKED "$WAIT_SECS" 1 3; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "thread 1 did not fetch tags 1 and 3" 255
fi

if _wait_queue_ready "${dev_id}"; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "queue 0 counted ready with tags 0 and 2 canceled" 255
fi

nr_io_ready=$(_ublk_nr_io_ready "${dev_id}")
if [ "$nr_io_ready" != 2 ]; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "nr_io_ready ${nr_io_ready}, expected 2 for tags 1 and 3" 255
fi

_end_test "nr_io_ready 2, dev ${dev_id} not LIVE" 0
