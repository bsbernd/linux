#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Run the QUIESCE_DEV cancel walk between the ->canceling test of a
# COMMIT_AND_FETCH_REQ and io_uring_cmd_mark_cancelable() on its command.
#
# A walk that completes the command before the mark leaves the completed
# request on the ring's cancelable list. The ring exit then walks into it:
# ublk_uring_cmd_cancel_fn() warns, and io_uring_try_cancel_uring_cmd() faults.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))
# QUIESCE_DEV has this long to walk the tag after the test sees the delay
# point fire
MARK_DELAY_US=$((3000000 * UBLK_WAIT_SCALE))

_prep_test "teardown" "QUIESCE_DEV cancel walk against the cancelable mark of a commit"

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# the delay point lives in the device's debugfs directory
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# depth 1: the cancel walk visits only the tag the read commits
dev_id=$(_add_ublk_dev -t null -q 1 -d 1 -r 1 --no_auto_part_scan)
_check_add_dev "$TID" $?

if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/delay_mark_cancelable" ]; then
	echo "no delay points (CONFIG_FAULT_INJECTION_DEBUG_FS)"
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _ublk_wait_no_inflight "${dev_id}" "$WAIT_SECS"; then
	echo "IO from the add still in flight"
	_cleanup_test
	_show_result $TID 255
fi
daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

# The read ends in the COMMIT_AND_FETCH_REQ before the delay point, so the
# tag holds no request and ublk_wait_for_idle_io() returns at once.
_ublk_arm_delay_point "${dev_id}" delay_mark_cancelable "$MARK_DELAY_US"
if ! _ublk_read_one_block "${dev_id}" < /dev/null > /dev/null 2>&1; then
	echo "read from dev ${dev_id} failed"
	ERR_CODE=255
elif ! _ublk_wait_delay_point_fired "${dev_id}" delay_mark_cancelable "$WAIT_SECS"; then
	echo "the COMMIT_AND_FETCH_REQ never reached the delay point"
	ERR_CODE=255
elif ! "${UBLK_PROG}" quiesce -n "${dev_id}" > /dev/null 2>&1; then
	echo "quiesce dev ${dev_id} failed"
	ERR_CODE=255
elif ! _ublk_wait_daemon_exit "$daemon_pid" "$WAIT_SECS"; then
	# the server exits once its only tag got UBLK_IO_RES_ABORT
	ERR_CODE=255
elif ! _ublk_wait_dev_state "${dev_id}" "QUIESCED" "$WAIT_SECS"; then
	# kublk closes its ring before /dev/ublkcN, so the ring exit is queued
	echo "dev ${dev_id} not QUIESCED ${WAIT_SECS}s after the server exited"
	_ublk_dump_dev_state "${dev_id}"
	ERR_CODE=255
fi

if ! _ublk_del_dev_timeout "${dev_id}"; then
	ERR_CODE=255
fi

if ! _check_dmesg; then
	echo "kernel complained after the quiesce"
	ERR_CODE=255
fi
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

_cleanup_test
_show_result $TID $ERR_CODE
