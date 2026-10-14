#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Quiesce a device while a commit is between ending its request and its
# ->canceling test, and a new request has already handed the commit's command
# to task work.
#
# The task work completes that command. If the commit completes it too, the
# task work later runs on a command io_uring has already completed. kublk's
# DEFER_TASKRUN ring runs it only after the server stopped on the abort, the
# server's exit then never ends, and the device never gets QUIESCED.
# delay_cancel_check holds the commit; the second read and QUIESCE_DEV run
# inside that delay.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))
# the second read, its task work and QUIESCE_DEV have to fit in here
CHECK_DELAY_US=5000000
# depth 1: the second read gets the tag of the first
DEV_ARGS="-t null -q 1 -d 1 -r 1 --no_auto_part_scan"

_prep_test "teardown" "quiesce while a commit's command is in task work"

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# the delay point and the tag flags live in the device's debugfs directory
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Usage: _wait_debugfs_text <file> <text>
_wait_debugfs_text()
{
	local tenths=0

	while [ "$tenths" -lt $((WAIT_SECS * 10)) ]; do
		if grep -q "$2" "$1"; then
			return 0
		fi
		sleep 0.1
		tenths=$((tenths + 1))
	done
	return 1
}

# milliseconds since the epoch
now_ms()
{
	echo $(($(date +%s%N) / 1000000))
}

# Usage: ublk_quiesce_tw_pending
ublk_quiesce_tw_pending()
{
	local dev_id
	local tags
	local dev_state
	local dd_pid=
	local quiesce_pid=
	local quiesce_rc
	local armed_ms
	local state
	local res=0

	# shellcheck disable=SC2086
	dev_id=$(_add_ublk_dev $DEV_ARGS)
	_check_add_dev "$TID" $?
	tags=${DEBUGFS_ROOT}/${dev_id}/tags
	dev_state=${DEBUGFS_ROOT}/${dev_id}/dev_state

	if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/delay_cancel_check" ]; then
		echo "no delay points (CONFIG_FAULT_INJECTION_DEBUG_FS)"
		_ublk_del_dev_timeout "${dev_id}"
		_cleanup_test
		exit "$UBLK_SKIP_CODE"
	fi

	if ! _ublk_wait_no_inflight "${dev_id}" "$WAIT_SECS"; then
		echo "IO from the add still in flight"
		res=1
	fi

	if [ "$res" -eq 0 ]; then
		# the commit sleeps from some point after this one
		armed_ms=$(now_ms)
		_ublk_arm_delay_point "${dev_id}" delay_cancel_check "$CHECK_DELAY_US"
		# returns once the commit ended the read; the commit then sleeps
		_ublk_read_one_block "${dev_id}" < /dev/null > /dev/null 2>&1
		if ! _ublk_wait_delay_point_fired "${dev_id}" delay_cancel_check "$WAIT_SECS"; then
			echo "the commit never reached the delay point"
			res=1
		fi
	fi

	if [ "$res" -eq 0 ]; then
		_ublk_read_one_block "${dev_id}" < /dev/null > /dev/null 2>&1 &
		# $! is the PID of the job just started with &
		dd_pid=$!
		if ! _wait_debugfs_text "$tags" CMD_TW_PENDING; then
			echo "the second read never handed the command to task work"
			res=1
		fi
	fi

	if [ "$res" -eq 0 ]; then
		"${UBLK_PROG}" quiesce -n "${dev_id}" &
		quiesce_pid=$!
		if ! _wait_debugfs_text "$dev_state" "canceling: 1"; then
			echo "QUIESCE_DEV never set ->canceling"
			res=1
		elif [ $(($(now_ms) - armed_ms)) -ge \
				$((CHECK_DELAY_US / 1000 - 500)) ]; then
			echo "->canceling was set too late to be inside the delay"
			res=1
		fi
	fi

	if [ -n "$quiesce_pid" ]; then
		wait "$quiesce_pid"
		quiesce_rc=$?
		if [ "$res" -eq 0 ] && [ "$quiesce_rc" -ne 0 ]; then
			echo "QUIESCE_DEV failed(${quiesce_rc})"
			res=1
		fi
	fi

	if ! _check_dmesg; then
		echo "kernel complained during quiesce"
		res=1
	fi
	# the server exits after its last command is aborted
	if [ "$res" -eq 0 ] && ! _ublk_wait_dev_state "${dev_id}" "QUIESCED" "$WAIT_SECS"; then
		echo "dev ${dev_id} not QUIESCED after QUIESCE_DEV"
		res=1
	fi
	# printed before the teardown below, which may not end
	if [ "$res" -eq 0 ]; then
		echo "verdict: pass"
	else
		echo "verdict: fail"
	fi

	if [ "$res" -eq 0 ]; then
		# shellcheck disable=SC2086
		state=$(_recover_ublk_dev -n "${dev_id}" $DEV_ARGS)
		if [ "$state" != "LIVE" ]; then
			echo "dev ${dev_id} isn't recovered($state)"
			res=1
		fi
	fi

	if ! _ublk_del_dev_timeout "${dev_id}"; then
		res=1
	fi
	if [ -n "$dd_pid" ]; then
		wait "$dd_pid" > /dev/null 2>&1
	fi
	return $res
}

if ! ublk_quiesce_tw_pending; then
	ERR_CODE=255
fi

if ! _check_dmesg; then
	echo "kernel complained during quiesce and recover"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
