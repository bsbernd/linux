#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# A canceled tag fetched again by another server task counts once.
#
# Two server threads share one queue with --per_io_tasks. Thread 0 fetches
# tags 0 and 2 and closes its ring, which cancels both commands. On SIGUSR2
# thread 1 fetches tags 0 and 2 again, then its own tags 1 and 3. The device
# must go LIVE only with all four tags fetched, and then serve reads.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))

_prep_test "teardown" "canceled tags fetched again by another task count once"

if ! _have_feature "PER_IO_DAEMON"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# tag states and the device state come only from debugfs
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# exec: the PID of the background job is then kublk itself
start_server()
{
	exec "${UBLK_PROG}" add -n "$1" -t null -q 1 -d 4 --nthreads 2 \
		--per_io_tasks --exit_after_fetch --takeover_after_exit \
		--no_auto_part_scan --foreground
}

# Usage: _end_test <message> <exit code>
_end_test()
{
	echo "$1"
	if ! _ublk_wait_daemon_gone "$daemon_pid" "$WAIT_SECS"; then
		ERR_CODE=255
	fi
	wait "$daemon_pid" > /dev/null 2>&1
	if ! _ublk_del_dev_timeout "$dev_id"; then
		ERR_CODE=255
	fi
	if ! _check_dmesg; then
		echo "kernel complained"
		ERR_CODE=255
	fi
	if [ "$2" -ne 0 ]; then
		ERR_CODE=$2
	fi
	if [ "$ERR_CODE" -eq 0 ]; then
		echo "verdict: pass"
	else
		echo "verdict: fail"
	fi
	_cleanup_test
	_show_result $TID $ERR_CODE
}

dev_id=$(_ublk_find_free_id)
# no fd of ours: a server stuck in exit must not hold the caller's pipe open
start_server "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
daemon_pid=$!

# a tag still holding its command refuses the second FETCH_REQ
if ! _ublk_wait_tags_show "${dev_id}" CANCELED "$WAIT_SECS" 0 2; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "closing thread 0's ring did not cancel tags 0 and 2" 255
fi

kill -USR2 "$daemon_pid"
if ! _ublk_wait_live "${dev_id}" "$WAIT_SECS"; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "dev ${dev_id} did not go LIVE" 255
fi

# UBLK_IO_FLAG_ACTIVE stays set while a fetched tag serves IO
if ! _ublk_tags_show "${dev_id}" ACTIVE 0 1 2 3; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "dev ${dev_id} LIVE with tags never fetched" 255
fi

udevadm settle --timeout=20
if ! timeout "$WAIT_SECS" dd if=/dev/ublkb"${dev_id}" of=/dev/null bs=4k \
		count=4 iflag=direct > /dev/null 2>&1; then
	_end_test "direct read from dev ${dev_id} failed" 255
fi

_end_test "tags 0 to 3 fetched, dev ${dev_id} LIVE and reading" 0
