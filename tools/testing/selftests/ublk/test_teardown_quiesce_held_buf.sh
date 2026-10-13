#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Quiesce a device while a tag has a fresh fetch command parked and its
# request still started.
#
# A server that keeps a zero copy buffer registered across
# COMMIT_AND_FETCH_REQ parks the tag again before the request ends: the
# request ends only when the buffer is unregistered. ublk_ctrl_quiesce_dev()
# makes one cancel pass. If that pass skips the tag, the server never gets
# UBLK_IO_RES_ABORT for it and the device never leaves LIVE.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))

_prep_test "teardown" "quiesce with a request held by its zero copy buffer"

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# the tags file is what shows the tag parked with its request started
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

_wait_quiesced()
{
	local dev_id=$1
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if [ "$(_get_ublk_dev_state "${dev_id}")" = "QUIESCED" ]; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

# A cancel pass that skips a started request waits on it for ever, and the
# exiting ring makes one, so the held request is ended before the kill.
_release_and_kill()
{
	kill -USR2 "$daemon_pid" > /dev/null 2>&1
	if [ -n "$dd_pid" ] && ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
		echo "the read did not end within ${WAIT_SECS}s of the unregister"
		ERR_CODE=255
	fi
	kill -9 "$daemon_pid" > /dev/null 2>&1
}

_fail_and_cleanup()
{
	echo "$1"
	_release_and_kill
	_cleanup_test
	_show_result $TID 255
}

dd_pid=""
dev_id=$(_add_ublk_dev -t null -q 1 -d 2 -r 1 -z --hold_zc_buf)
_check_add_dev "$TID" $?
daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

# udev has settled, so the next request to arrive is the read below
read -r reads writes < /sys/block/ublkb"${dev_id}"/inflight
if [ "$reads" -ne 0 ] || [ "$writes" -ne 0 ]; then
	_fail_and_cleanup "IO in flight before the hold: ${reads} ${writes}"
fi

kill -USR1 "$daemon_pid"
# no fd of ours: a read that never ends must not hold the caller's pipe open
_ublk_read_one_block "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
dd_pid=$!

if ! _ublk_wait_kmsg "kublk: dev ${dev_id} tag [0-9]* committed, buffer held" \
		"$WAIT_SECS"; then
	_fail_and_cleanup "kublk did not commit with the buffer held"
fi
if ! grep -q "REQ_STARTED  CMD_PARKED" "${DEBUGFS_ROOT}/${dev_id}/tags"; then
	_ublk_dump_dev_state "${dev_id}"
	_fail_and_cleanup "no tag parked with its request started"
fi

if ! "${UBLK_PROG}" quiesce -n "${dev_id}"; then
	_fail_and_cleanup "QUIESCE_DEV failed"
fi
if ! _wait_quiesced "${dev_id}"; then
	echo "dev ${dev_id} isn't quiesced ${WAIT_SECS}s after QUIESCE_DEV"
	_ublk_dump_dev_state "${dev_id}"
	ERR_CODE=255
fi

_release_and_kill

if ! _ublk_del_dev_timeout "${dev_id}"; then
	ERR_CODE=255
fi

if ! _check_dmesg; then
	echo "kernel complained during quiesce"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
