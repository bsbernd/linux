#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Stop a batch device whose live server has no FETCH_IO_CMDS command left.
#
# A FETCH_IO_CMDS command ends with -ENOBUFS once its buffer is used up.
# --no_refetch_on_enobufs makes kublk queue no new one and stay up, so the
# tags of later reads wait in the driver's evts_fifo. STOP_DEV then waits in
# del_gendisk() for those reads, and ublk_stop_dev() cancels the queue only
# after del_gendisk() returns. The same reads and STOP_DEV with a server that
# queues a new fetch command come first and must end.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))
# two fetch commands of 2048 tags each run out before this many reads
NR_READS=8192

_prep_test "teardown" "stop a batch device whose server dropped its fetches"

if ! _have_feature "BATCH_IO"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Usage: stop_after_reads refetch|drop <add args...>
# $1: drop adds --no_refetch_on_enobufs
stop_after_reads()
{
	local fetch=$1
	local daemon_pid
	local dev_id
	local dd_pid
	local stop_pid
	local res=0

	shift 1
	if [ "$fetch" = drop ]; then
		dev_id=$(_add_ublk_dev "$@" --no_refetch_on_enobufs)
	else
		dev_id=$(_add_ublk_dev "$@")
	fi
	_check_add_dev "$TID" $?
	daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

	dd if=/dev/ublkb"${dev_id}" of=/dev/null iflag=direct bs=4k \
		count="$NR_READS" < /dev/null > /dev/null 2>&1 &
	# $! is the PID of the reader
	dd_pid=$!

	if [ "$fetch" = drop ]; then
		if ! _ublk_wait_kmsg "kublk: dev ${dev_id} thread 0 dropped 2 fetch commands" \
				"$WAIT_SECS"; then
			echo "kublk on dev ${dev_id} did not drop both fetch commands"
			res=1
		elif ! _ublk_wait_reads_inflight "${dev_id}" 1 "$WAIT_SECS"; then
			echo "the read after the dropped fetch commands never reached the driver"
			res=1
		fi
	elif ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
		echo "${NR_READS} reads on dev ${dev_id} did not end in ${WAIT_SECS}s"
		res=1
	fi

	"${UBLK_PROG}" stop -n "${dev_id}" < /dev/null > /dev/null 2>&1 &
	# $! is the PID of the STOP_DEV sender
	stop_pid=$!
	if ! _ublk_wait_pid_gone "$stop_pid" "$WAIT_SECS"; then
		echo "STOP_DEV of dev ${dev_id} did not return in ${WAIT_SECS}s: del_gendisk() waits for reads with no fetch command"
		res=1
	fi

	# the ring exit of the killed server makes its release fail the reads
	kill -9 "$daemon_pid" > /dev/null 2>&1
	if ! _ublk_wait_pid_gone "$stop_pid" "$WAIT_SECS"; then
		echo "STOP_DEV of dev ${dev_id} still waits after killing the server"
		res=1
	fi
	if ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
		echo "the reads on dev ${dev_id} did not end"
		res=1
	fi
	if ! _ublk_del_dev_timeout "${dev_id}"; then
		res=1
	fi
	return $res
}

if ! stop_after_reads refetch -t null -q 1 -b; then
	ERR_CODE=255
fi
if ! stop_after_reads drop -t null -q 1 -b; then
	ERR_CODE=255
fi
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

if ! _check_dmesg; then
	echo "kernel complained during stop"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
