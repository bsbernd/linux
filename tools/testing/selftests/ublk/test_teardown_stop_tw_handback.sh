#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Stop a device while the dispatch task work of a read has not run yet.
#
# The command of the read's tag is out of the tag until ublk_cmd_tw_cb() hands
# it back, and the one-pass cancel walk of STOP_DEV skips a tag without one.
# With IORING_SETUP_DEFER_TASKRUN the task work runs only when the server
# thread reaps, and --park_on_signal holds that thread until STOP_DEV returned.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))

_prep_test "teardown" "stop before a dispatch task work hands its command back"

# the verdict is the tag state in debugfs
if ! debugfs_root=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# killing the parked server ends its ring, which completes its commands
_fail_and_cleanup()
{
	echo "$1"
	kill -9 "$daemon_pid"
	_cleanup_test
	_show_result $TID 255
}

# depth 1: tag 0 is the read's tag and the only one the cancel walk visits
dev_id=$(_add_ublk_dev -t null -q 1 -d 1 --park_on_signal)
_check_add_dev "$TID" $?
daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")
tags_file="${debugfs_root}/${dev_id}/tags"

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
if ! _ublk_wait_tag_flag_present "${dev_id}" CMD_TW_PENDING "$WAIT_SECS"; then
	_fail_and_cleanup "the read's task work was never queued"
fi

# ends the read from the dispatch list; the cancel walk skips tag 0
if ! "${UBLK_PROG}" stop -n "${dev_id}"; then
	_fail_and_cleanup "STOP_DEV failed"
fi

# the task work runs now and hands the command back
kill -USR2 "$daemon_pid"

# only UBLK_IO_RES_ABORT on the handed-back command lets the server exit
if ! _ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"; then
	echo "server ${daemon_pid} still running ${WAIT_SECS}s after the resume"
	ERR_CODE=255
fi
if grep -q CMD_PARKED "$tags_file"; then
	echo "tag 0 holds a command on a stopped device:"
	_ublk_dump_dev_state "${dev_id}"
	ERR_CODE=255
fi
# printed before the teardown below, which may not end
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

# the parked command is still on the ring's cancelable list, so the ring exit
# completes it
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
