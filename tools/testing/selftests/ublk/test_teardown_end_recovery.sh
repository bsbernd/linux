#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# A recovery server that dies before it has fetched every I/O command must not
# deadlock its own exit.
#
# END_USER_RECOVERY waits for every queue to have fetched all its commands, and
# only the server can fetch, so a server that dies mid-fetch asks for something
# nobody can deliver. The command may sleep, so io_uring always runs it from an
# io-wq worker of that same thread group: if the wait does not give up, do_exit()
# waits for the worker and the worker waits for the server that is exiting. The
# task ends up unkillable in D state, which is why this test asserts that the
# recover command exits at all rather than checking a result code alone.
#
# The worker deadlocks only when it reaches the wait after get_signal() took
# the kill. The delay point ready_wait_late holds END_USER_RECOVERY until the
# server is exiting, then drops what get_signal() would have consumed.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))
# upper bound only: the point returns as soon as the server is exiting
LATE_US=$((WAIT_SECS * 1000000))
# each queue thread parks before fetching tag 1, so readiness never comes
PARK_US=600000000

_prep_test "teardown" "END_USER_RECOVERY with a server that dies mid-fetch"

# Echo the line ready_wait_late logged for <dev_id> since _prep_test.
# Usage: _ready_wait_late_line <dev_id>
_ready_wait_late_line()
{
	local from

	from=$(dmesg | grep -n "ublk selftest: ${TID} starting" | tail -1 |
		cut -d: -f1)
	dmesg | tail -n +$((from + 1)) | grep -o "ublk$1: ready_wait_late: .*"
}

# Usage: _wait_ready_wait_late_line <dev_id>
_wait_ready_wait_late_line()
{
	local line
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		line=$(_ready_wait_late_line "$1")
		if [ -n "$line" ]; then
			echo "$line"
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

# A task that finished do_exit() is a zombie until the shell reaps it.
# Usage: _task_exited <pid>
_task_exited()
{
	local state

	if ! read -r _ _ state _ 2> /dev/null < /proc/"$1"/stat; then
		return 0
	fi
	[ "$state" = "Z" ]
}

# Usage: _wait_task_exited <pid>
_wait_task_exited()
{
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if _task_exited "$1"; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

ublk_run_end_recovery()
{
	local recover_pid
	local recover_res
	local dev_id
	local state
	local line
	local res=0

	dev_id=$(_add_ublk_dev -t fault_inject -r 1 -q 2)
	_check_add_dev "$TID" $?

	if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/ready_wait_late" ]; then
		echo "no delay points (CONFIG_FAULT_INJECTION_DEBUG_FS)"
		_cleanup_test
		exit "$UBLK_SKIP_CODE"
	fi

	state=$(__ublk_kill_daemon "${dev_id}" "QUIESCED")
	if [ "$state" != "QUIESCED" ]; then
		echo "device isn't quiesced($state) before recovery"
		_ublk_del_dev_timeout "${dev_id}"
		return 1
	fi

	# armed after the add, so START_DEV does not take it
	_ublk_arm_delay_point "${dev_id}" ready_wait_late "$LATE_US"
	"${UBLK_PROG}" recover -n "${dev_id}" --foreground \
		-t fault_inject --die_during_fetch 1 \
		--die_during_fetch_delay_us "$PARK_US" > /dev/null 2>&1 &
	# $! is the PID of the job just started with &
	recover_pid=$!

	if ! _ublk_wait_delay_point_fired "${dev_id}" ready_wait_late "$WAIT_SECS"; then
		echo "END_USER_RECOVERY never reached ublk_wait_dev_ready_and_lock()"
		res=1
	fi
	kill -9 "$recover_pid" > /dev/null 2>&1

	if [ "$res" -eq 0 ]; then
		line=$(_wait_ready_wait_late_line "${dev_id}")
		if [ "${line#*: ready_wait_late: }" != \
		     "group_exit 1, notify_signal 1, sigpending 0" ]; then
			echo "precondition not reached: ${line:-no ready_wait_late line}"
			res=1
		fi
	fi

	# A hang here is the bug: the dying task waits in do_exit() for the
	# io-wq worker running END_USER_RECOVERY, and that worker waits for a
	# readiness only the dying task could deliver.
	if [ "$res" -eq 0 ] && ! _wait_task_exited "$recover_pid"; then
		echo "recover did not exit: END_USER_RECOVERY never returned"
		res=1
	fi
	if [ "$res" -eq 0 ]; then
		wait "$recover_pid"
		recover_res=$?
		# 137 is the result when dying of SIGKILL
		if [ "$recover_res" -ne 137 ]; then
			echo "recover command exited with unexpected code ${recover_res}!"
			res=1
		fi
	fi
	# printed before the teardown below, which may not end
	if [ "$res" -eq 0 ]; then
		echo "verdict: pass"
	else
		echo "verdict: fail"
	fi

	_ublk_del_dev_timeout "${dev_id}" || res=1
	return $res
}

# the delay point lives in the device's debugfs directory
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

ublk_run_end_recovery || ERR_CODE=255

if ! _check_dmesg; then
	echo "kernel complained during end recovery teardown"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
