#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Read from a QUIESCED recovery device, then recover it with a new server.
#
# With UBLK_F_USER_RECOVERY a request issued while no server runs waits for the
# next server. The read must succeed once the new server is live, for a
# classic and for a batch device.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))

_prep_test "teardown" "read from a quiesced device, then recover it"

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Read one block and write the exit code of dd to <dd_res file>.
# Usage: read_block_res <dev_id> <dd_res file>
read_block_res()
{
	dd if=/dev/ublkb"$1" of=/dev/null iflag=direct bs=4k count=1
	# $? is the exit code of dd
	echo $? > "$2"
}

# Usage: quiesce_read_recover <add args...>
quiesce_read_recover()
{
	local dd_err="${UBLK_TEST_DIR}/dd_err"
	local dd_res_file="${UBLK_TEST_DIR}/dd_res"
	local dev_id
	local dd_pid
	local dd_res
	local state
	local res=0

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	state=$(__ublk_quiesce_dev "${dev_id}" "QUIESCED")
	if [ "$state" != "QUIESCED" ]; then
		echo "dev ${dev_id} isn't quiesced(${state})"
		_ublk_del_dev_timeout "${dev_id}"
		return 1
	fi

	rm -f "$dd_res_file"
	read_block_res "${dev_id}" "$dd_res_file" < /dev/null > /dev/null \
		2> "$dd_err" &
	# $! is the PID of the reader, which waits for the new server
	dd_pid=$!

	# a read failed by the driver ends dd in this time, a waiting one does not
	if _ublk_wait_pid_gone "$dd_pid" "$UBLK_STATE_SLEEP"; then
		echo "read on QUIESCED dev ${dev_id} (add $*) ended before recovery:"
		head -n 1 "$dd_err"
		res=1
	fi

	state=$(_recover_ublk_dev -n "${dev_id}" "$@")
	if [ "$state" != "LIVE" ]; then
		echo "dev ${dev_id} isn't recovered(${state})"
		res=1
	fi

	if [ "$res" -eq 0 ]; then
		if ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
			echo "read on dev ${dev_id} did not return in ${WAIT_SECS}s after recovery"
			kill -9 "$dd_pid" > /dev/null 2>&1
			res=1
		else
			dd_res=$(cat "$dd_res_file")
			if [ "$dd_res" != 0 ]; then
				echo "read on dev ${dev_id} failed(${dd_res}) after recovery:"
				head -n 1 "$dd_err"
				res=1
			fi
		fi
	fi

	if ! _ublk_del_dev_timeout "${dev_id}"; then
		res=1
	fi
	rm -f "$dd_err" "$dd_res_file"
	return $res
}

if ! quiesce_read_recover -t null -r 1; then
	ERR_CODE=255
fi
if _have_feature "BATCH_IO"; then
	if ! quiesce_read_recover -t null -r 1 -b; then
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
