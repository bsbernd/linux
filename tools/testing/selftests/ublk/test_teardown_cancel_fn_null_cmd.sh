#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Kill the server while the STOP_DEV cancel walk completes a command it took.
#
# ublk_cancel_cmd() clears io->cmd, drops its locks and only then completes
# the command, which stays on io_uring's cancelable list until then. The delay
# point holds the walk in between, and the server exit runs ->cancel_fn() on
# the same command meanwhile, which finds io->cmd NULL. A driver that warns
# about that fails the kernel log check.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))
# the server exit has this long to reach the tag
WALK_DELAY_US=3000000

_prep_test "teardown" "kill the server while the cancel walk completes a command"

if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

_end_early()
{
	echo "$1"
	kill -9 "$daemon_pid"
	_ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"
	_ublk_del_dev_timeout "${dev_id}"
	_cleanup_test
	_show_result $TID "$2"
}

# depth one: the walk's first tag holds the only fetch command
dev_id=$(_add_ublk_dev -t null -q 1 -d 1 --no_auto_part_scan)
_check_add_dev "$TID" $?
daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/delay_cancel_cmd_done" ]; then
	_end_early "no delay point (CONFIG_FAULT_INJECTION_DEBUG_FS)" \
		"$UBLK_SKIP_CODE"
fi
_ublk_arm_delay_point "${dev_id}" delay_cancel_cmd_done "$WALK_DELAY_US"

"${UBLK_PROG}" stop -n "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
stop_pid=$!
if ! _ublk_wait_delay_point_fired "${dev_id}" delay_cancel_cmd_done \
		"$WAIT_SECS"; then
	_end_early "STOP_DEV did not reach ublk_cancel_cmd()" 255
fi

# the server exit runs ->cancel_fn() on the command the walk holds
kill -9 "$daemon_pid"
if ! _ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"; then
	echo "server ${daemon_pid} still running ${WAIT_SECS}s after the kill"
	ERR_CODE=255
fi
if ! _ublk_wait_pid_gone "$stop_pid" "$WAIT_SECS"; then
	echo "STOP_DEV did not return within ${WAIT_SECS}s"
	ERR_CODE=255
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
