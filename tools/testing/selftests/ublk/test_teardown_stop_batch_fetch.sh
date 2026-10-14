#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Stop a batch device while the dispatch task work of a read has not run yet.
#
# The read makes one fetch command active. STOP_DEV ends the read and leaves
# the active fetch command on the queue for its task work. With
# IORING_SETUP_DEFER_TASKRUN that task work runs only when the server thread
# reaps, and --park_on_signal holds that thread until STOP_DEV returned.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))

_prep_test "teardown" "stop before a batch dispatch task work runs"

# the verdict is the fetch command count in debugfs
if ! debugfs_root=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Usage: _wait_fetch_cmd_active <dev_state file>
_wait_fetch_cmd_active()
{
	local state_file=$1
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if grep -q "fetch_cmds [0-9]* active 1" "$state_file"; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

# killing the parked server ends its ring, which completes its commands
_fail_and_cleanup()
{
	echo "$1"
	kill -9 "$daemon_pid"
	_cleanup_test
	_show_result $TID 255
}

dev_id=$(_add_ublk_dev -t null -b -q 1 -d 4 --nthreads 1 --park_on_signal \
	--no_auto_part_scan)
_check_add_dev "$TID" $?
daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")
state_file="${debugfs_root}/${dev_id}/dev_state"

if ! grep -q "fetch_cmds" "$state_file"; then
	_fail_and_cleanup "dev_state shows no fetch commands"
fi

if ! _ublk_wait_reads_inflight "${dev_id}" 0 "$WAIT_SECS"; then
	_fail_and_cleanup "IO from the add still in flight"
fi

kill -USR1 "$daemon_pid"
if ! _ublk_wait_kmsg "kublk: dev ${dev_id} stopped reaping" "$WAIT_SECS"; then
	_fail_and_cleanup "kublk did not stop reaping"
fi

_ublk_read_one_block "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
dd_pid=$!
if ! _wait_fetch_cmd_active "$state_file"; then
	_fail_and_cleanup "the read never made a fetch command active"
fi

# ends the read; the cancel walk leaves the active fetch command queued
if ! "${UBLK_PROG}" stop -n "${dev_id}"; then
	_fail_and_cleanup "STOP_DEV failed"
fi
echo "after STOP_DEV:"
grep "fetch_cmds" "$state_file"

# the task work runs now and releases the active fetch command
kill -USR2 "$daemon_pid"

# only UBLK_IO_RES_ABORT on that fetch command lets the server exit
if ! _ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"; then
	echo "server ${daemon_pid} still running ${WAIT_SECS}s after the resume"
	if grep -q "fetch_cmds [1-9]" "$state_file"; then
		echo "the stopped device still holds a fetch command:"
	else
		echo "the stopped device holds no fetch command:"
	fi
	_ublk_dump_dev_state "${dev_id}"
	ERR_CODE=255
elif grep -q "fetch_cmds [1-9]" "$state_file"; then
	echo "fetch command left after the server exit:"
	grep "fetch_cmds" "$state_file"
	ERR_CODE=255
fi
# printed before the teardown below, which may not end
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

# the held fetch command is still on the ring's cancelable list, so the ring
# exit completes it
if [ "$ERR_CODE" -ne 0 ]; then
	kill -9 "$daemon_pid" 2> /dev/null
	_ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"
fi
# the read ended with an error at STOP_DEV
wait "$dd_pid" > /dev/null 2>&1

if ! _ublk_del_dev_timeout "${dev_id}"; then
	ERR_CODE=255
fi

if ! _check_dmesg; then
	echo "kernel complained during the stop"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
