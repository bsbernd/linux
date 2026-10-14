#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Kill a batch server while the STOP_DEV cancel walk holds a fetch command.
#
# ublk_batch_cancel_queue() moves the queue's fetch commands to its own list.
# The delay point holds ublk_batch_cancel_queue() after it picked the first
# fetch command off that list. The server exit runs ->cancel_fn() on the same
# fetch commands meanwhile. Unless ublk_batch_cancel_queue() takes its entry
# under evts_lock, ->cancel_fn() frees the entry ublk_batch_cancel_queue()
# then completes; a KASAN kernel reports that use after free in dmesg.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))
# the server exit has this long to cancel the fetch commands
WALK_DELAY_US=3000000

_prep_test "teardown" "kill a batch server during the STOP_DEV cancel walk"

if ! debugfs_root=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# should_fail() counts times down to 0 when it fires. Polled in tenths: the
# server kill has to land within WALK_DELAY_US.
# Usage: _wait_delay_point_fired <dir>
_wait_delay_point_fired()
{
	local dir=$1
	local tenths=0

	while [ "$tenths" -lt $((WAIT_SECS * 10)) ]; do
		if [ "$(cat "${dir}/times")" -eq 0 ]; then
			return 0
		fi
		sleep 0.1
		tenths=$((tenths + 1))
	done
	return 1
}

_end_early()
{
	echo "$1"
	kill -9 "$daemon_pid"
	_ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"
	_ublk_del_dev_timeout "${dev_id}"
	_cleanup_test
	_show_result $TID "$2"
}

dev_id=$(_add_ublk_dev -t null -b -q 1 -d 4 --nthreads 1 --no_auto_part_scan)
_check_add_dev "$TID" $?
daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")
delay_dir="${debugfs_root}/${dev_id}/delay_batch_cancel_walk"

if [ ! -d "$delay_dir" ]; then
	_end_early "no delay point (CONFIG_FAULT_INJECTION_DEBUG_FS)" \
		"$UBLK_SKIP_CODE"
fi
echo 0 > "${delay_dir}/verbose"
echo 100 > "${delay_dir}/probability"
echo 1 > "${delay_dir}/times"
echo "$WALK_DELAY_US" > "${delay_dir}/delay_us"

"${UBLK_PROG}" stop -n "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
stop_pid=$!
if ! _wait_delay_point_fired "$delay_dir"; then
	_end_early "STOP_DEV did not reach the batch cancel walk" 255
fi

# the server exit runs ->cancel_fn() on every fetch command of the queue
kill -9 "$daemon_pid"
if ! _ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"; then
	echo "server ${daemon_pid} still running ${WAIT_SECS}s after the kill"
	ERR_CODE=255
fi
if ! _ublk_wait_pid_gone "$stop_pid" "$WAIT_SECS"; then
	echo "STOP_DEV did not return within ${WAIT_SECS}s"
	ERR_CODE=255
fi

# printed before the teardown below, which may not end
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

if ! _ublk_del_dev_timeout "${dev_id}"; then
	ERR_CODE=255
fi
if ! _check_dmesg; then
	echo "kernel complained during the stop"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
