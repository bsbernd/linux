#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Keep IO running across kill and recover, and delete only later.
#
# This covers IO reaching a recovered device whose tags the new server has not
# all fetched yet. ublk_prep_req() refuses requests while ->canceling is set,
# so that is the only interval where ublk_queue_rqs() can reach a tag holding
# no command.
#
# fio submits in batches because ublk_queue_rqs() is only called for a plug
# holding more than one request, and the cycle repeats because a single kill
# leaves too small a window.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
CYCLES=8
RUNTIME=10

_prep_test "teardown" "kill the queue daemon under fio without recovery"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# ublk_queue_rqs() compares two tags before dispatching them together, and
# reads ->cmd out of the cmd/req union to do it. Cancellation clears ->cmd, so
# a tag it already took has none to compare -- ublk_prep_req() refuses new
# requests only while ->canceling is set, and it reads that flag before the
# plug path reads ->cmd.
#
# Without UBLK_F_USER_RECOVERY the device goes DEAD rather than QUIESCED, so
# there is no recovery to re-fetch the tags and no ready-gate in the way. This
# is the shape that reproduced it in the ublksrv suite (tests/generic/002).
ublk_kill_daemon_no_recovery()
{
	local dev_id
	local fio_pid
	local state

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	# iodepth_batch so the plug holds more than one request: a batch of one
	# never reaches the comparison
	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=rw --norandommap --iodepth=64 --iodepth_batch=32 \
		--bs=4k --numjobs=4 --runtime=$RUNTIME --time_based \
		> /dev/null 2>&1 &
	fio_pid=$!

	_ublk_sleep 2 3

	state=$(__ublk_kill_daemon "${dev_id}" "DEAD")
	if [ "$state" != "DEAD" ]; then
		echo "dev ${dev_id} isn't dead($state) after killing the daemon"
		ERR_CODE=255
	fi

	# no recovery, so teardown fails the requests rather than queueing them
	# and fio unblocks on its own. _ublk_del_dev_timeout() belongs to a
	# later patch than this one, so the plain delete is what is available
	# here -- a delete that wedges is reported by the runner's timeout.
	_ublk_del_dev "${dev_id}"
	udevadm settle

	kill -9 $fio_pid > /dev/null 2>&1
	wait $fio_pid > /dev/null 2>&1
}

for ((cycle = 0; cycle < CYCLES; cycle++)); do
	ublk_kill_daemon_no_recovery -t null -q 2 -d 64
	# NEED_GET_DATA adds a round trip before the handover, which widens the
	# interval a tag spends holding no command.
	#
	# The ublksrv case this is ported from also passes -u 1, but that is
	# its uring_comp option; here -u selects user copy, which is a data
	# copy mode and cannot be combined with -g.
	ublk_kill_daemon_no_recovery -t null -q 2 -d 64 -g
	[ "$ERR_CODE" -ne 0 ] && break
done

if ! _check_dmesg; then
	echo "kernel complained after killing the queue daemon"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
