#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Send one more FETCH_REQ from a server thread whose task work STOP_DEV waits for.
#
# STOP_DEV holds ub->mutex across del_gendisk(), which waits for the read below.
# The read's task work is queued on the server thread, and with
# IORING_SETUP_DEFER_TASKRUN it runs only when that thread reaps again. If the
# FETCH_REQ sleeps on ub->mutex, the thread never reaps and both hang in D state.
#
# A hang cannot be cleaned up from here, so on that path the test reports and
# exits, leaving the device behind.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
EBUSY=16
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))

_prep_test "teardown" "FETCH_REQ on a started device while STOP_DEV runs"

if ! _have_feature "NO_AUTO_PART_SCAN"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# without the stop_dev step there is no telling that STOP_DEV holds ub->mutex
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# The driver records the stop_dev step under ub->mutex, right before
# del_gendisk(), and keeps the mutex until del_gendisk() returns.
_wait_stop_dev_step()
{
	local dev_id=$1
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if grep -q "^steps:.* stop_dev" "${DEBUGFS_ROOT}/${dev_id}/teardown"; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

# Before SIGUSR2 nothing is stuck yet: killing the parked server ends its
# rings, which lets the read and STOP_DEV finish, and the device can go.
_fail_and_cleanup()
{
	echo "$1"
	kill -9 "$daemon_pid"
	_cleanup_test
	_show_result $TID 255
}

dev_id=$(_add_ublk_dev -t null -q 1 -d 4 --no_auto_part_scan \
	--refetch_on_signal)
_check_add_dev "$TID" $?
daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

kill -USR1 "$daemon_pid"
if ! _ublk_wait_kmsg "kublk: dev ${dev_id} stopped reaping" "$WAIT_SECS"; then
	_fail_and_cleanup "kublk did not stop reaping"
fi

# no fd of ours: a dd stuck in D state must not hold the caller's pipe open
_ublk_read_one_block "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
dd_pid=$!
if ! _ublk_wait_read_inflight "${dev_id}" "$WAIT_SECS"; then
	_fail_and_cleanup "the read never reached the driver"
fi

_ublk_stop_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
stop_pid=$!
if ! _wait_stop_dev_step "${dev_id}"; then
	_fail_and_cleanup "STOP_DEV never reached del_gendisk()"
fi

kill -USR2 "$daemon_pid"

# Without the fix the FETCH_REQ sleeps on ub->mutex for ever: kublk, STOP_DEV
# and dd stay in D state and nothing here can end them.
if ! _ublk_wait_kmsg "kublk: dev ${dev_id} FETCH_REQ on tag 0: res -${EBUSY}$" \
		"$WAIT_SECS"; then
	echo "FETCH_REQ not refused with -EBUSY within ${WAIT_SECS}s"
	_show_result $TID 255
fi
if ! _ublk_wait_pid_gone "$stop_pid" "$WAIT_SECS"; then
	echo "STOP_DEV did not return within ${WAIT_SECS}s"
	_show_result $TID 255
fi
if ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
	echo "the read did not end within ${WAIT_SECS}s"
	_show_result $TID 255
fi

if ! _ublk_del_dev_timeout "${dev_id}"; then
	ERR_CODE=255
fi

if ! _check_dmesg; then
	echo "kernel complained during STOP_DEV"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
