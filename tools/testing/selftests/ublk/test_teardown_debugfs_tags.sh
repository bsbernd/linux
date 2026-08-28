#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Cover ublk/<dev_id>/dev_state and ublk/<dev_id>/tags themselves.
#
# They are the only view of per-tag state from userspace, and the teardown
# cases take their verdict from them. Check that they report the geometry the
# device was created with, that tags stays readable while
# ublk_debugfs_tags_show() walks state the IO path is changing underneath, and
# that the directory goes away with the device.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
NR_QUEUES=2
DEPTH=32

_prep_test "teardown" "read the device and tag state from debugfs"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

dev_id=$(_add_ublk_dev -t null -q "$NR_QUEUES" -d "$DEPTH")
_check_add_dev $TID $?

DEV_DIR="${DEBUGFS_ROOT}/${dev_id}"

if [ ! -f "${DEV_DIR}/dev_state" ] || [ ! -f "${DEV_DIR}/tags" ]; then
	echo "dev ${dev_id} has no debugfs files"
	_cleanup_test
	_show_result $TID 255
fi

_dev_state_field() {
	grep "^$1: " "${DEV_DIR}/dev_state" | cut -d' ' -f2
}

_check_field() {
	local got
	got=$(_dev_state_field "$1")
	if [ "$got" != "$2" ]; then
		echo "dev_state $1 is '$got', expected '$2'"
		ERR_CODE=255
	fi
}

_check_field dev_id "$dev_id"
_check_field state LIVE
_check_field nr_hw_queues "$NR_QUEUES"
_check_field queue_depth "$DEPTH"

# every queue the device reports must have a line of its own
for ((qid = 0; qid < NR_QUEUES; qid++)); do
	if ! grep -q "^queue ${qid}: " "${DEV_DIR}/dev_state"; then
		echo "dev_state has no line for queue ${qid}"
		ERR_CODE=255
	fi
done

# reading tags while requests are in flight is the case worth covering,
# since the file walks per-tag state the IO path is changing underneath
fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
	--rw=randrw --norandommap --iodepth=32 --bs=4k --numjobs=2 \
	--runtime=4 --time_based > /dev/null 2>&1 &
fio_pid=$!

for ((i = 0; i < 20; i++)); do
	if ! cat "${DEV_DIR}/tags" > /dev/null 2>&1; then
		echo "reading tags failed while IO was in flight"
		ERR_CODE=255
		break
	fi
done

wait $fio_pid

# an idle device holds no request on the ublk server
if grep -q "OWNED_BY_SRV" "${DEV_DIR}/tags"; then
	echo "a tag is still owned by the server on an idle device"
	sed 's/^/\t/' "${DEV_DIR}/tags"
	ERR_CODE=255
fi

_ublk_del_dev "${dev_id}"
udevadm settle

# the directory is named after a device number that is reusable again
if [ -d "${DEV_DIR}" ]; then
	echo "debugfs dir for dev ${dev_id} outlived the device"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
