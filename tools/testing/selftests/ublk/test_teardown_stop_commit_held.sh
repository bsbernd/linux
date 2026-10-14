#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Commit a request that STOP_DEV took from the server holding it.
#
# The device has one tag and the server holds its read, so after STOP_DEV no
# command of the server is parked and the cancel walk completes none. The
# server's later commit on that tag is its only notice of the teardown: unless
# it ends with UBLK_IO_RES_ABORT, the queue thread waits for ever with nothing
# in flight. Judged by the server exiting on its own.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
# one tag: a FETCH_REQ parked on a second tag would get the abort instead
DEV_ARGS="-t null -q 1 -d 1 --hold_io_on_signal --no_auto_part_scan"

_prep_test "teardown" "commit a request STOP_DEV took from the server"

if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# ub_disk drops to 0 once del_gendisk() returned
# Usage: _wait_disk_detached <dev_id>
_wait_disk_detached()
{
	local dev_state=${DEBUGFS_ROOT}/$1/dev_state
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if grep -q "^ub_disk: 0$" "$dev_state" 2>/dev/null; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

del_dev()
{
	"${UBLK_PROG}" del -n "$1"
}

dev_id=$(_add_ublk_dev $DEV_ARGS)
_check_add_dev "$TID" $?
server_pid=$(_get_ublk_daemon_pid "${dev_id}")

# armed only once the reads udev issued at add were served
if ! _ublk_wait_no_inflight "${dev_id}" "$WAIT_SECS"; then
	echo "IO from the add still in flight after ${WAIT_SECS}s"
	ERR_CODE=255
fi
kill -USR1 "$server_pid"

_ublk_read_one_block "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
dd_pid=$!
if ! _ublk_wait_tag_flag_present "${dev_id}" OWNED_BY_SRV "$WAIT_SECS"; then
	echo "the server did not hold the read"
	ERR_CODE=255
fi

del_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
del_pid=$!
if [ "$ERR_CODE" -eq 0 ] && ! _wait_disk_detached "${dev_id}"; then
	echo "del_gendisk() of dev ${dev_id} wedged"
	ERR_CODE=255
fi
# the premise: STOP_DEV took the tag while the server still holds the read
if [ "$ERR_CODE" -eq 0 ] &&
		! _ublk_wait_tag_flag_gone "${dev_id}" OWNED_BY_SRV "$WAIT_SECS"; then
	ERR_CODE=255
fi
if [ "$ERR_CODE" -eq 0 ] && ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
	echo "the read did not end after STOP_DEV took its tag"
	ERR_CODE=255
fi

# SIGUSR2 makes the server commit the read it held
kill -USR2 "$server_pid"
if [ "$ERR_CODE" -eq 0 ] && ! _ublk_wait_pid_gone "$server_pid" "$WAIT_SECS"; then
	echo "server of dev ${dev_id} still running ${WAIT_SECS}s after its commit"
	ps -L -o pid,tid,stat,wchan:32,args -p "$server_pid"
	_ublk_dump_dev_state "${dev_id}"
	ERR_CODE=255
fi
# printed before the teardown below, which may not end
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

# The delete returns once the server released the device, so a stuck one is
# killed.
if ! _ublk_wait_pid_gone "$server_pid" 1; then
	kill -9 "$server_pid"
fi
if ! _ublk_wait_pid_gone "$del_pid" "$WAIT_SECS"; then
	echo "delete dev ${dev_id} still wedged after the server exited"
	ERR_CODE=255
fi
if ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
	echo "the read still in flight after ${WAIT_SECS}s"
fi
sed -i "/^${dev_id}$/d" "${UBLK_TEST_DIR}/.ublk_devs"
if ! _check_dmesg; then
	echo "kernel complained during the delete"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
