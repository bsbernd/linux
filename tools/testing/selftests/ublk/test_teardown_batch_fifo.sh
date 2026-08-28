#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Tear down a UBLK_F_BATCH_IO device with tags still queued on ubq->evts_fifo.
#
# ublk_batch_dispatch_fail() puts a tag back on the fifo, and a tag that is
# never dispatched again carries whatever the failed handoff left in io->ref
# and io->task_registered_buffers into teardown, which WARNs on both. A deep
# fifo is the point: the default depth is too shallow to leave tags queued
# behind the drain when the delete arrives.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
LOOPS=2
RUNTIME=10

_prep_test "teardown" "batch teardown with a deep event fifo"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _have_feature "BATCH_IO"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

_create_backfile 0 256M

# An undispatched tag holds no reference and counts no registered buffer.
# Teardown WARNs on a tag that carries either, but only for a device that
# reaches teardown -- this reads the same state while the device is alive.
_check_batch_tags_idle()
{
	local dev_id=$1
	local dir
	local bad

	dir=$(_ublk_debugfs_root) || return 0
	[ -f "${dir}/${dev_id}/tags" ] || return 0

	bad=$(grep "^  tag " "${dir}/${dev_id}/tags" |
		grep -v " ref 0 reg_bufs 0 ")
	if [ -n "$bad" ]; then
		echo "tags hold references on an idle device:"
		echo "$bad" | sed 's/^/\t/'
		return 1
	fi
	return 0
}

dev_id=$(_add_ublk_dev -t null -q 2 -d 256 -b)
_check_add_dev $TID $?

fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
	--rw=randrw --norandommap --iodepth=256 --bs=4k --numjobs=4 \
	--runtime=5 --time_based > /dev/null 2>&1

_check_batch_tags_idle "${dev_id}" || ERR_CODE=255
_ublk_del_dev_timeout "${dev_id}" || ERR_CODE=255

# depth 256 over two queues leaves many tags queued behind the drain when
# the delete arrives; the shallower batch arms elsewhere never build a
# backlog for a failed handoff to be reinserted into
for ((loop = 0; loop < LOOPS; loop++)); do
	_ublk_run_del_mid_io 4k randrw 4 $RUNTIME \
		-t null -q 2 -d 256 -b || ERR_CODE=255
	_ublk_run_del_mid_io 4k randrw 4 $RUNTIME \
		-t loop -q 2 -d 256 -b "${UBLK_BACKFILES[0]}" || ERR_CODE=255

	if _have_feature "AUTO_BUF_REG"; then
		# auto_zc is what makes a handoff register a buffer, so a tag
		# put back with a stale count is one teardown WARNs about
		_ublk_run_del_mid_io 4k randrw 4 $RUNTIME \
			-t loop -q 2 -d 256 -b --auto_zc \
			"${UBLK_BACKFILES[0]}" || ERR_CODE=255
	fi
done

# The server dying is the other way the fifo gets drained, and it drains it
# from the char device release rather than from a delete. Both readers pop
# under evts_lock, so KCSAN has something to compare once teardown can drain
# while a dispatch is still running.
ublk_kill_with_deep_fifo()
{
	local dev_id
	local fio_pid
	local state

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=randrw --norandommap --iodepth=256 --bs=4k --numjobs=4 \
		--runtime=30 --time_based > /dev/null 2>&1 &
	fio_pid=$!

	sleep 2

	state=$(__ublk_kill_daemon "${dev_id}" "QUIESCED")
	if [ "$state" != "QUIESCED" ]; then
		echo "dev ${dev_id} isn't quiesced($state) after kill"
		ERR_CODE=255
	fi

	# A tag taken off the fifo never reached the server, so the drain
	# gives it back rather than leaving it marked for a dispatch that is
	# not going to happen. The device survives the kill here, which a
	# deleted one does not, so the state can still be read.
	_ublk_wait_tag_flag_gone "${dev_id}" DISPATCHING 30 || ERR_CODE=255

	# a quiesced recovery device holds its IO by design, so fio cannot be
	# waited for until the device is gone
	_ublk_del_dev_timeout "${dev_id}" || ERR_CODE=255

	kill -INT $fio_pid > /dev/null 2>&1
	_ublk_wait_fio "$fio_pid" 60 || ERR_CODE=255
}

ublk_kill_with_deep_fifo -t null -q 2 -d 256 -b -r 1
ublk_kill_with_deep_fifo -t loop -q 2 -d 256 -b -r 1 "${UBLK_BACKFILES[0]}"

if ! _check_dmesg; then
	echo "kernel complained during batch teardown"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
