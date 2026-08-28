#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Land a delete while the server is inside a copy through /dev/ublkcN.
#
# Only the loop target copies that way, and the stress cases delete after a
# fixed sleep without bounding the delete, so nothing lands one while
# ublk_user_copy() still holds a request. The recovery reissue arm covers the
# other disposition teardown can pick, where the request is requeued rather
# than ended under the copy.
#
# io->ref is checked on an idle device: a wrong sum only shows up as a
# refcount_t report otherwise.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
LOOPS=2
RUNTIME=10

_prep_test "teardown" "delete landing in a user copy"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _have_feature "USER_COPY"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

_create_backfile 0 256M

# A completed tag has dropped every reference it took, so an idle device
# holds none. Reading that back needs the device alive, which rules out
# checking it after the delete below.
#
# fio returning does not make the device idle: the partition scan and udev
# read it too, so a tag can legitimately hold a reference for a moment after.
# Only one that never drops it is a leak, so this polls rather than samples.
# Usage: _check_refs_settled <dev_id> <deadline>
_check_refs_settled()
{
	local dev_id=$1
	local deadline=$2
	local secs=0
	local dir
	local bad

	dir=$(_ublk_debugfs_root) || return 0
	[ -f "${dir}/${dev_id}/tags" ] || return 0

	while [ "$secs" -lt "$deadline" ]; do
		bad=$(grep -v " ref 0 " "${dir}/${dev_id}/tags" | grep "^  tag ")
		[ -z "$bad" ] && return 0
		sleep 1
		secs=$((secs + 1))
	done

	echo "references outstanding ${deadline}s after the device went idle:"
	echo "$bad" | sed 's/^/\t/'
	return 1
}

dev_id=$(_add_ublk_dev -t loop -q 2 -u "${UBLK_BACKFILES[0]}")
_check_add_dev $TID $?

fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
	--rw=randrw --norandommap --iodepth=64 --bs=64k --numjobs=2 \
	--runtime=5 --time_based > /dev/null 2>&1

_check_refs_settled "${dev_id}" 30 || ERR_CODE=255

_ublk_del_dev_timeout "${dev_id}" || ERR_CODE=255

# Only the loop target copies through /dev/ublkcN, so the delete has to land
# on a loop device for the server to be inside a copy when it arrives. Large
# blocks keep it there longer.
for ((loop = 0; loop < LOOPS; loop++)); do
	_ublk_run_del_mid_io 64k randrw 4 $RUNTIME \
		-t loop -q 2 -u "${UBLK_BACKFILES[0]}" || ERR_CODE=255

	# reissue makes teardown requeue the request instead of ending it,
	# which is the other disposition the copy reference has to outlive
	_ublk_run_del_mid_io 64k randrw 4 $RUNTIME \
		-t loop -q 2 -u -r 1 -i 1 "${UBLK_BACKFILES[0]}" || ERR_CODE=255
done

if ! _check_dmesg; then
	echo "kernel complained during teardown"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
