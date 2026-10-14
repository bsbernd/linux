#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Send a plugged batch of reads to tags whose commands were canceled before
# the device started.
#
# Two server threads share one queue with --per_io_tasks. Thread 0 fetches
# tags 0 and 2 and closes its ring, which cancels both commands. On SIGUSR2
# thread 1 fetches tags 1 and 3: the queue counts as ready, ->canceling is
# cleared and the device goes LIVE with tags 0 and 2 holding no command.
# ublk_queue_rqs() compares the tags of neighbouring requests in a batch and
# must not read a command out of tag 0 or 2.
#
# The oops leaves started requests that teardown cannot end, so on that path
# the test reports and exits, leaving the device behind.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
LIVE_SECS=$((5 * UBLK_WAIT_SCALE))

_prep_test "teardown" "plugged reads on tags canceled before START_DEV"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _have_feature "PER_IO_DAEMON"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# the tag states are read from debugfs, nothing else shows them
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# START_DEV waits in the driver until every tag of the queue is counted ready.
_wait_dev_live()
{
	local dev_id=$1
	local secs=0

	while [ "$secs" -lt "$LIVE_SECS" ]; do
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
	exec "${UBLK_PROG}" add -n "$1" -t null -q 1 -d 4 --nthreads 2 \
		--per_io_tasks --exit_after_fetch --no_auto_part_scan --foreground
}

# io_submit() of more than two iocbs plugs. Depth 4 gives all three reads a
# tag without sleeping, so blk_finish_plug() hands them to ublk_queue_rqs()
# together, and any three of the four tags include tag 0 or 2.
read_batch()
{
	fio --name=batch --filename=/dev/ublkb"$1" --ioengine=libaio --direct=1 \
		--rw=randread --norandommap --bs=4k --iodepth=3 \
		--iodepth_batch_submit=3 --number_ios=3
}

# Before the reads nothing has raced yet: the server and the device can go.
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

if ! _ublk_wait_tags_show "${dev_id}" CANCELED "$WAIT_SECS" 0 2; then
	_ublk_dump_dev_state "${dev_id}"
	_end_early "closing thread 0's ring did not cancel tags 0 and 2" 255
fi

kill -USR2 "$daemon_pid"
if ! _ublk_wait_tags_show "${dev_id}" CMD_PARKED "$WAIT_SECS" 1 3; then
	_ublk_dump_dev_state "${dev_id}"
	_end_early "thread 1 did not fetch tags 1 and 3" 255
fi

# a driver that keeps a queue with canceled tags from going ready ends here
if ! _wait_dev_live "${dev_id}"; then
	_end_early "dev ${dev_id} not LIVE with tags 0 and 2 canceled" "$UBLK_SKIP_CODE"
fi
udevadm settle --timeout=20

# an elevator dispatches through ublk_queue_rq(), one request at a time
echo none > /sys/block/ublkb"${dev_id}"/queue/scheduler
echo 2 > /sys/block/ublkb"${dev_id}"/queue/nomerges

read_batch "${dev_id}" < /dev/null > /dev/null 2>&1 &
fio_pid=$!

# fio's exit code is not judged: with the fix the reads on tags 0 and 2 fail
if ! _ublk_wait_pid_gone "$fio_pid" "$WAIT_SECS"; then
	echo "fio did not end within ${WAIT_SECS}s"
	ERR_CODE=255
fi
if ! _check_dmesg; then
	echo "kernel complained on the batch of reads"
	ERR_CODE=255
fi
if [ "$ERR_CODE" -ne 0 ]; then
	echo "verdict: fail"
	_show_result $TID $ERR_CODE
fi

if ! _ublk_del_dev_timeout "${dev_id}"; then
	ERR_CODE=255
fi
if [ "$ERR_CODE" -eq 0 ] && ! _ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"; then
	echo "kublk did not exit within ${WAIT_SECS}s"
	ERR_CODE=255
fi
if ! _check_dmesg; then
	echo "kernel complained while deleting the device"
	ERR_CODE=255
fi
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

_cleanup_test
_show_result $TID $ERR_CODE
