#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# A FETCH_REQ must not make the queue ready while a cancel of another tag
# is between ublk_start_cancel() and ublk_cancel_cmd().
#
# Two server threads share one queue of depth 2 with --per_io_tasks. Thread
# 0 fetches tag 0 and closes its ring on SIGUSR1; delay_cancel_fn holds the
# ring's exit work after ublk_start_cancel(). Inside the delay thread 1
# fetches tag 1 on SIGUSR2. Tag 0 then holds no command, so the queue must
# end at nr_io_ready 1 and the device must not go LIVE.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
READY_SECS=$((5 * UBLK_WAIT_SCALE))
# thread 1's FETCH_REQ takes well under a second
CANCEL_DELAY_US=3000000

_prep_test "teardown" "queue not ready when it fills during a cancel"

if ! _have_feature "PER_IO_DAEMON"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# tag states and nr_io_ready come only from debugfs
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Usage: _arm_delay_point <dev_id> <name> <delay_us>
_arm_delay_point()
{
	local dir=${DEBUGFS_ROOT}/$1/$2

	echo 0 > "${dir}/verbose"
	echo 100 > "${dir}/probability"
	echo 1 > "${dir}/times"
	echo "$3" > "${dir}/delay_us"
}

# Return 0 once the queue counts both tags ready or the device is LIVE.
_wait_queue_ready()
{
	local dev_id=$1
	local secs=0

	while [ "$secs" -lt "$READY_SECS" ]; do
		if [ "$(_ublk_nr_io_ready "$dev_id")" = 2 ]; then
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
	exec "${UBLK_PROG}" add -n "$1" -t null -q 1 -d 2 --nthreads 2 \
		--per_io_tasks --exit_after_fetch --exit_on_signal \
		--no_auto_part_scan --foreground
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

if ! _ublk_wait_tags_show "${dev_id}" CMD_PARKED "$WAIT_SECS" 0; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "thread 0 did not fetch tag 0" 255
fi

if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/delay_cancel_fn" ]; then
	echo "no delay_cancel_fn (CONFIG_FAULT_INJECTION_DEBUG_FS)"
	kill -9 "$daemon_pid"
	_ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"
	_ublk_del_dev_timeout "$dev_id"
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

_arm_delay_point "${dev_id}" delay_cancel_fn "$CANCEL_DELAY_US"
kill -USR1 "$daemon_pid"
if ! _ublk_wait_delay_point_fired "${dev_id}" delay_cancel_fn "$WAIT_SECS"; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "closing thread 0's ring did not reach the cancel of tag 0" 255
fi

kill -USR2 "$daemon_pid"
if ! _ublk_wait_tags_show "${dev_id}" CANCELED "$WAIT_SECS" 0; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "the cancel of tag 0 did not finish" 255
fi
if ! _ublk_wait_tags_show "${dev_id}" CMD_PARKED "$WAIT_SECS" 1; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "thread 1 did not fetch tag 1" 255
fi

if _wait_queue_ready "${dev_id}"; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "queue 0 counted ready with tag 0 canceled" 255
fi

nr_io_ready=$(_ublk_nr_io_ready "${dev_id}")
if [ "$nr_io_ready" != 1 ]; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "nr_io_ready ${nr_io_ready}, expected 1 for tag 1" 255
fi

_end_test "nr_io_ready 1, dev ${dev_id} not LIVE" 0
