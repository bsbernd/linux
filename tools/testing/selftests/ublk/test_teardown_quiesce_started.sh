#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Quiesce a device while a read is started but not yet handed to the server.
#
# ublk_ctrl_quiesce_dev() makes a single cancel pass, and ublk_cancel_cmd()
# skips a tag whose request is started. The read's dispatch then hands the tag
# to the server, whose COMMIT_AND_FETCH_REQ parks a new command that no cancel
# pass visits: the server never gets UBLK_IO_RES_ABORT for that tag.
#
# The read's dispatch is task work on the server thread, and with
# IORING_SETUP_DEFER_TASKRUN it runs only when that thread reaps again. The
# thread is parked while the quiesce runs, so the cancel pass always sees the
# read started. The same quiesce of a parked server without the read comes
# first and must end QUIESCED.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))

_prep_test "teardown" "quiesce while a read is started"

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Usage: quiesce_parked yes|no
# $1: yes starts a read while the server is parked
quiesce_parked()
{
	local with_read=$1
	local daemon_pid
	local dev_id
	local dd_pid=""
	local res=0

	# depth 2: the read leaves a tag idle, so ublk_wait_for_idle_io() returns
	dev_id=$(_add_ublk_dev -t null -q 1 -d 2 -r 1 --park_on_signal)
	_check_add_dev "$TID" $?
	daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

	if ! _ublk_wait_reads_inflight "${dev_id}" 0 "$WAIT_SECS"; then
		echo "IO from the add still in flight"
		res=1
	fi

	if [ "$res" -eq 0 ]; then
		kill -USR1 "$daemon_pid"
		if ! _ublk_wait_kmsg "kublk: dev ${dev_id} stopped reaping" \
				"$WAIT_SECS"; then
			echo "kublk did not stop reaping"
			res=1
		fi
	fi

	if [ "$res" -eq 0 ] && [ "$with_read" = yes ]; then
		_ublk_read_one_block "${dev_id}" < /dev/null > /dev/null 2>&1 &
		# $! is the PID of the job just started with &
		dd_pid=$!
		if ! _ublk_wait_reads_inflight "${dev_id}" 1 "$WAIT_SECS"; then
			echo "the read never reached the driver"
			res=1
		fi
	fi

	# returns after the cancel pass, which skipped the started read
	if [ "$res" -eq 0 ] && ! "${UBLK_PROG}" quiesce -n "${dev_id}"; then
		echo "QUIESCE_DEV failed"
		res=1
	fi

	if [ "$res" -eq 0 ]; then
		# the dispatch runs now: the server serves the read and commits
		kill -USR2 "$daemon_pid"
		# the server exits once each tag got UBLK_IO_RES_ABORT, and
		# only its exit makes the device QUIESCED
		if ! _ublk_wait_dev_state "${dev_id}" "QUIESCED" "$WAIT_SECS"; then
			echo "dev ${dev_id} still $(_get_ublk_dev_state "${dev_id}") ${WAIT_SECS}s after QUIESCE_DEV (read: ${with_read}): a tag was never aborted"
			res=1
		fi
	fi

	# The ring exit of the killed server cancels a command left parked, and
	# the read is ended by its commit or, unserved, requeued until delete.
	if [ "$res" -ne 0 ]; then
		kill -9 "$daemon_pid"
		if ! _ublk_wait_dev_state "${dev_id}" "QUIESCED" "$WAIT_SECS"; then
			echo "dev ${dev_id} not QUIESCED after killing the server"
		fi
	fi

	if ! _ublk_del_dev_timeout "${dev_id}"; then
		res=1
	fi
	if [ -n "$dd_pid" ] && ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
		echo "the read did not end after delete"
		res=1
	fi
	return $res
}

if ! quiesce_parked no; then
	ERR_CODE=255
fi
if ! quiesce_parked yes; then
	ERR_CODE=255
fi
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

if ! _check_dmesg; then
	echo "kernel complained during quiesce"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
