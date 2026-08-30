#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Delete a device whose request the server still owns and never commits.
#
# del_gendisk() waits for started requests, and only the server ends a request
# it owns, so teardown has to fail those itself before it gets there.
#
# --hold_io stops the server completing what it fetched, leaving the tag
# UBLK_IO_FLAG_OWNED_BY_SRV, and that state is asserted through debugfs before
# deleting: a delete that finds no owned request proves nothing. This one needs
# no race, so a single run either reproduces or does not.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0

_prep_test "teardown" "delete a device whose request the server still owns"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# the owned tag is the whole premise, so without debugfs there is nothing to
# assert and the delete below would prove nothing
if ! _ublk_debugfs_root > /dev/null; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# A server that never completes what it fetched leaves the request
# UBLK_IO_FLAG_OWNED_BY_SRV. del_gendisk() waits for started requests, and only
# the server ends an owned one, so teardown has to fail it before getting
# there. No race: the server simply never commits.
ublk_hold_and_delete()
{
	local dev_id
	local fio_pid

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=randread --iodepth=1 --bs=4k --numjobs=1 \
		--runtime=60 --time_based > /dev/null 2>&1 &
	fio_pid=$!

	# assert the state rather than assume it: without a tag actually owned
	# by the server, the delete below proves nothing
	# nothing below proves anything without a tag the server actually owns,
	# and on that path the device is healthy enough to clean up
	if ! _ublk_wait_tag_flag_present "${dev_id}" OWNED_BY_SRV 10; then
		echo "no tag reached OWNED_BY_SRV -- --hold_io did not engage"
		ERR_CODE=255
		kill -9 $fio_pid > /dev/null 2>&1
		wait $fio_pid > /dev/null 2>&1
		_show_result $TID $ERR_CODE
	fi

	# del_gendisk() waits uninterruptibly, so a delete that never completes
	# cannot be bounded from here: timeout(1) cannot kill a task in D state
	# and neither can SIGKILL. Without the fix this call does not return and
	# the runner's own timeout is what reports it -- along with a module
	# that will not unload afterwards.
	_ublk_del_dev_timeout "${dev_id}" || ERR_CODE=255

	kill -9 $fio_pid > /dev/null 2>&1
	wait $fio_pid > /dev/null 2>&1
}

# Depth has to exceed the number of tags fio keeps in flight. A held tag is
# already OWNED_BY_SRV, so its fetch command was consumed at the handover and
# there is nothing left on it to abort; without spare tags still holding parked
# commands the server never sees UBLK_IO_RES_ABORT, never exits, never releases
# /dev/ublkcN, and the delete waits on ublk_idr_wq whatever teardown does.
ublk_hold_and_delete -t null -q 1 -d 4 --hold_io
ublk_hold_and_delete -t null -q 2 -d 8 --hold_io

if ! _check_dmesg; then
	echo "kernel complained deleting a device with an owned request"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
