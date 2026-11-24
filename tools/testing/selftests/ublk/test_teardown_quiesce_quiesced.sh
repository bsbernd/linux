#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Quiesce a QUIESCED device whose new server has fetched, but not yet ended
# the recovery.
#
# QUIESCE_DEV reports success on a device that is not LIVE. Unless it also
# skips ublk_cancel_dev() there, it aborts the new server's FETCH commands:
# kublk exits, or a batch queue gets force_abort and fails every request.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
NR_TAGS=2

_prep_test "teardown" "quiesce a quiesced device with a new server"

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Usage: quiesce_quiesced <add args...>
quiesce_quiesced()
{
	local dev_id
	local server_pid
	local state
	local dd_res
	local res=0

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	state=$(__ublk_kill_daemon "${dev_id}" "QUIESCED")
	if [ "$state" != "QUIESCED" ]; then
		echo "dev ${dev_id} isn't quiesced(${state}) after kill"
		res=1
	fi

	if [ "$res" -eq 0 ] && ! "${UBLK_PROG}" recover -n "${dev_id}" "$@" \
			--no_end_recovery > /dev/null; then
		echo "recover of dev ${dev_id} failed"
		res=1
	fi
	if [ "$res" -eq 0 ]; then
		sleep "$UBLK_STATE_SLEEP"
		# the new server never ended the recovery, so kublk list has the old pid
		server_pid=$(_ublk_char_dev_holder "${dev_id}")
		if [ -z "$server_pid" ]; then
			echo "no new server holds /dev/ublkc${dev_id} after recover"
			res=1
		fi
	fi

	if [ "$res" -eq 0 ] && ! "${UBLK_PROG}" quiesce -n "${dev_id}"; then
		echo "quiesce of the quiesced dev ${dev_id} failed"
		res=1
	fi
	if [ "$res" -eq 0 ]; then
		# dispatched to a tag whose command QUIESCE_DEV aborted, the read
		# finds io->cmd NULL in ublk_queue_cmd()
		timeout "$WAIT_SECS" dd if=/dev/ublkb"${dev_id}" of=/dev/null \
			iflag=direct bs=4k count=1 < /dev/null > /dev/null 2>&1
		# $? is the exit code of timeout, 124 when it killed dd
		dd_res=$?
		if [ "$dd_res" -eq 124 ]; then
			echo "dd on /dev/ublkb${dev_id} did not return in ${WAIT_SECS}s"
			res=1
		elif [ "$dd_res" -ne 0 ]; then
			echo "dd on /dev/ublkb${dev_id} failed(${dd_res}) after the second QUIESCE_DEV"
			res=1
		elif ! kill -0 "$server_pid" 2>/dev/null; then
			echo "new server ${server_pid} of dev ${dev_id} exited after the second QUIESCE_DEV"
			res=1
		fi
	fi

	if [ -n "$server_pid" ] && [ "$server_pid" -gt 0 ]; then
		kill -9 "$server_pid" > /dev/null 2>&1
	fi
	if ! _ublk_del_dev_timeout "${dev_id}"; then
		res=1
	fi
	return $res
}

if ! quiesce_quiesced -t null -q 1 -d "$NR_TAGS" -r 1; then
	ERR_CODE=255
fi
if _have_feature "BATCH_IO"; then
	if ! quiesce_quiesced -t null -q 1 -d "$NR_TAGS" -r 1 -b; then
		ERR_CODE=255
	fi
fi
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

if ! _check_dmesg; then
	echo "kernel complained during quiesce and recover"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
