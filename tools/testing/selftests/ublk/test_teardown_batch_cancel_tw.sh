#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Kill a UBLK_F_BATCH_IO server with task work still queued.
#
# io_uring then runs that task work with cancel set, and for batch mode it is
# the only chance the fetch command gets: it is ubq->active_fcmd, which
# ublk_batch_cancel_cmd() skips, so a command left parked there keeps
# referencing /dev/ublkcN and DEL_DEV waits on ublk_idr_wq for ever.
#
# Whether task work is outstanding when the ring dies cannot be arranged, so
# the kill lands at a different point each cycle, over many cycles.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
CYCLES=10
RUNTIME=5

_prep_test "teardown" "kill a batch server with task work still queued"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _have_feature "BATCH_IO"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# io_uring runs pending task work with the cancel token set only when the ring
# actually goes away, so the server has to die rather than park: --abandon_ring
# keeps the ring alive and never reaches this path. A fetch command left parked
# in that run is ubq->active_fcmd, which cancellation deliberately skips, so it
# keeps referencing /dev/ublkcN and UBLK_U_CMD_DEL_DEV waits on ublk_idr_wq.
#
# Whether task work is outstanding at the instant the ring dies is not
# something the test can arrange, so kill at a different point each cycle and
# take many cycles rather than one.
ublk_batch_kill_with_tw()
{
	local dev_id
	local fio_pid
	local daemon_pid
	local cycle

	for ((cycle = 0; cycle < CYCLES; cycle++)); do
		dev_id=$(_add_ublk_dev "$@")
		_check_add_dev "$TID" $?

		# deep queues and a large batch: tags reach ubq->evts_fifo and
		# get queued to task work faster than the server drains them
		fio --name=job1 --filename=/dev/ublkb"${dev_id}" \
			--ioengine=libaio --rw=randrw --norandommap \
			--iodepth=256 --iodepth_batch=32 --bs=4k --numjobs=4 \
			--runtime=$RUNTIME --time_based > /dev/null 2>&1 &
		fio_pid=$!

		daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")
		if [ -z "$daemon_pid" ] || [ "$daemon_pid" -le 0 ] 2>/dev/null; then
			echo "no daemon pid for dev ${dev_id}"
			ERR_CODE=255
			kill -9 $fio_pid > /dev/null 2>&1
			wait $fio_pid > /dev/null 2>&1
			_show_result $TID $ERR_CODE
		fi

		sleep 0.$((RANDOM % 9 + 1))
		kill -9 "$daemon_pid" > /dev/null 2>&1
		_ublk_wait_daemon_gone "$daemon_pid" 30 || ERR_CODE=255

		# A stranded fetch command holds the char device, so without
		# the fix this never returns and the runner's timeout reports
		# it -- along with a module that will not unload.
		_ublk_del_dev_timeout "${dev_id}" || ERR_CODE=255

		kill -9 $fio_pid > /dev/null 2>&1
		wait $fio_pid > /dev/null 2>&1

		[ "$ERR_CODE" -ne 0 ] && break
	done
}

# --die_during_fetch cannot be used to place this window: the fault_inject
# target raises SIGKILL only for tag 1, and the batch path calls pre_fetch_io
# once per queue with tag 0, so a batch server never dies there.

_create_backfile 0 256M

ublk_batch_kill_with_tw -t null -q 2 -d 128 -b
ublk_batch_kill_with_tw -t loop -q 2 -d 64 -b "${UBLK_BACKFILES[0]}"

if ! _check_dmesg; then
	echo "kernel complained after the batch server was killed"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
