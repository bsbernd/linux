#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Run the STOP_DEV cancel walk between ublk_fetch() of a FETCH_REQ and
# io_uring_cmd_mark_cancelable() on its command.
#
# A walk that completes the command before the mark leaves the completed
# request on the ring's cancelable list. The ring exit then never finishes,
# so /dev/ublkcN, a fixed file of the ring, stays open after the server died.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
# STOP_DEV has this long to walk tag 0 after the test sees the delay point
# fire
MARK_DELAY_US=$((3000000 * UBLK_WAIT_SCALE))

_prep_test "teardown" "STOP_DEV cancel walk against the cancelable mark of a FETCH_REQ"

if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# ublk_ch_release() clears the "open" bit of ub_state in debugfs.
# Usage: _wait_cdev_released <dev_id>
_wait_cdev_released()
{
	local state=${DEBUGFS_ROOT}/$1/dev_state
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if [ "$(awk '$1 == "ub_state:" { print $4 }' "$state")" = 0 ]; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

# exec: the PID of the background job is then kublk itself, which takes the
# signals
start_server()
{
	exec "${UBLK_PROG}" add -n "$1" -t null -q 1 -d 4 --foreground \
		--refetch_on_signal --refetch_unready
}

del_dev()
{
	"${UBLK_PROG}" del -n "$1"
}

# Before SIGUSR2 nothing has raced yet: the server and the device can go.
# Usage: _end_early <message> <exit code>
_end_early()
{
	echo "$1"
	kill -9 "$daemon_pid"
	_ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"
	_ublk_del_dev_timeout "$dev_id"
	_cleanup_test
	_show_result $TID "$2"
}

dev_id=$(_ublk_free_dev_id)
# no fd of ours: a server stuck in exit must not hold the caller's pipe open
start_server "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
daemon_pid=$!

# Tags 2 and 3 parked: the IO thread runs and takes SIGUSR1.
if ! _ublk_wait_tags_parked "${dev_id}" 2 "$WAIT_SECS"; then
	_end_early "kublk did not fetch tags 2 and 3" 255
fi
if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/delay_mark_cancelable" ]; then
	_end_early "no delay points (CONFIG_FAULT_INJECTION_DEBUG_FS)" \
		"$UBLK_SKIP_CODE"
fi

kill -USR1 "$daemon_pid"
if ! _ublk_wait_kmsg "kublk: dev ${dev_id} stopped reaping" "$WAIT_SECS"; then
	_end_early "kublk did not stop reaping" 255
fi
# armed only now, so only the FETCH_REQ on tag 0 takes it
_ublk_arm_delay_point "${dev_id}" delay_mark_cancelable "$MARK_DELAY_US"
kill -USR2 "$daemon_pid"

# The device never gets ready, so ublk_stop_dev() only walks the tags.
if ! _ublk_wait_delay_point_fired "${dev_id}" delay_mark_cancelable "$WAIT_SECS"; then
	echo "the FETCH_REQ on tag 0 never reached the delay point"
	ERR_CODE=255
else
	_ublk_stop_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
	stop_pid=$!
	if ! _ublk_wait_pid_gone "$stop_pid" "$WAIT_SECS"; then
		echo "STOP_DEV did not return within ${WAIT_SECS}s"
		ERR_CODE=255
	fi
fi

kill -9 "$daemon_pid"
if ! _ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"; then
	echo "kublk still exiting after ${WAIT_SECS}s"
	ERR_CODE=255
elif ! _wait_cdev_released "${dev_id}"; then
	echo "/dev/ublkc${dev_id} still open ${WAIT_SECS}s after kublk exited"
	ERR_CODE=255
fi
if ! _check_dmesg; then
	echo "kernel complained after STOP_DEV"
	ERR_CODE=255
fi
# printed before the delete below, which may not end after a failure
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

del_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
del_pid=$!
if ! _ublk_wait_pid_gone "$del_pid" "$WAIT_SECS"; then
	echo "DEL_DEV did not return within ${WAIT_SECS}s"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
