#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Quiesce a device while a dispatch gives up before the handover.
#
# ublk_ctrl_quiesce_dev() makes a single cancel pass and skips every tag whose
# request is started, which is safe only when the dispatch reaches the
# handover. ublk_auto_buf_dispatch() gives up when the buffer cannot be
# registered and no fallback was asked for, and the server is then left
# waiting for a fetch command nobody completes.
#
# The read's dispatch is task work on the server thread, and with
# IORING_SETUP_DEFER_TASKRUN it runs only when that thread reaps again. The
# thread is parked while the quiesce runs, so the cancel pass always sees the
# read started; --bad_buf_index makes the registration fail once it reaps.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))

_prep_test "teardown" "quiesce landing in an abandoned dispatch"

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# --bad_buf_index fails only an automatic buffer registration
if ! _have_feature "AUTO_BUF_REG"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Before SIGUSR2 nothing is stuck yet: killing the parked server ends its
# ring, which cancels every command parked there, and the device can go.
_fail_and_cleanup()
{
	echo "$1"
	kill -9 "$daemon_pid"
	_cleanup_test
	_show_result $TID 255
}

# depth 2: the read leaves a tag idle, so ublk_wait_for_idle_io() returns
dev_id=$(_add_ublk_dev -t null -q 1 -d 2 -r 1 --auto_zc --bad_buf_index \
	--park_on_signal)
_check_add_dev "$TID" $?
daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

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
if ! _ublk_wait_reads_inflight "${dev_id}" 1 "$WAIT_SECS"; then
	_fail_and_cleanup "the read never reached the driver"
fi

# returns after the cancel pass, which skipped the started read
if ! "${UBLK_PROG}" quiesce -n "${dev_id}"; then
	_fail_and_cleanup "QUIESCE_DEV failed"
fi

# the dispatch runs now, and the buffer registration fails
kill -USR2 "$daemon_pid"

# the server exits once each tag got UBLK_IO_RES_ABORT, and only its exit
# makes the device QUIESCED
if ! _ublk_wait_dev_state "${dev_id}" "QUIESCED" "$WAIT_SECS"; then
	echo "dev ${dev_id} not QUIESCED ${WAIT_SECS}s after the resume"
	_ublk_dump_dev_state "${dev_id}"
	ERR_CODE=255
fi
# printed before the teardown below, which may not end
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

# The server still waits for the abandoned command: its ring exit takes it,
# as the request is ended by now.
if [ "$ERR_CODE" -ne 0 ]; then
	kill -9 "$daemon_pid"
	if ! _ublk_wait_dev_state "${dev_id}" "QUIESCED" "$WAIT_SECS"; then
		echo "dev ${dev_id} not QUIESCED after killing the server"
	fi
fi
# the read ended with an error when the registration failed
wait "$dd_pid" > /dev/null 2>&1

if ! _ublk_del_dev_timeout "${dev_id}"; then
	ERR_CODE=255
fi

if ! _check_dmesg; then
	echo "kernel complained during quiesce"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
