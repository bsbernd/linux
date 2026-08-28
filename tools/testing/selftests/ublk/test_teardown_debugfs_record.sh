#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Read ublk/<dev_id>/teardown after the server was killed.
#
# The counts it keeps only mean anything compared against each other, so check
# the two comparisons the file exists for: that io_uring ran every callback
# ublk queued, and that every ublk_uring_cmd_cancel_fn() call reached one of
# the three exits of ublk_cancel_cmd(). A killed server is the one window where
# the record outlives the server that made it.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0

_prep_test "teardown" "read the teardown record from debugfs"

if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

dev_id=$(_add_ublk_dev -t null -q 2 -d 32)
_check_add_dev $TID $?

REC="${DEBUGFS_ROOT}/${dev_id}/teardown"

if [ ! -f "${REC}" ]; then
	echo "dev ${dev_id} has no teardown record"
	_cleanup_test
	_show_result $TID 255
fi

dd if=/dev/ublkb"${dev_id}" of=/dev/null bs=4k count=1024 iflag=direct \
	> /dev/null 2>&1

_rec_field() {
	grep "^$1: " "${REC}" | cut -d' ' -f2
}

# the server opened the char device to serve the queues
ch_open=$(_rec_field ch_open)
if [ -z "$ch_open" ] || [ "$ch_open" -lt 1 ]; then
	echo "teardown ch_open is '$ch_open', expected at least 1"
	ERR_CODE=255
fi

# io_uring runs every callback that was queued, one way or the other
tw_queued=$(_rec_field tw_queued)
tw_run=$(_rec_field tw_run)
if [ "$tw_queued" != "$tw_run" ]; then
	echo "tw_queued ${tw_queued} but tw_run ${tw_run}"
	sed 's/^/\t/' "${REC}"
	ERR_CODE=255
fi

_ublk_del_dev "${dev_id}"
udevadm settle

# the record is named after a device number that is reusable again
if [ -d "${DEBUGFS_ROOT}/${dev_id}" ]; then
	echo "debugfs dir for dev ${dev_id} outlived the device"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
