#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Quiesce a depth-one queue in the interval where a request is handed over.
#
# The other quiesce cases let the queue fill first, so the cancel pass runs
# against tags that already carry a command and the handover follows it rather
# than racing it. One queue of depth one with no ramp-up puts the only request
# in flight between being started and being published, which is where a
# dispatch can hand over to a server that is already gone.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
CYCLES=4
RUNTIME=30

_prep_test "teardown" "no tag may be handed over once the queue is canceling"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Same scenario as test_teardown_quiesce_dispatch.sh, different assertion.
# That one checks no tag is left UBLK_IO_FLAG_DISPATCHING, which is what
# UBLK_IO_FLAG_DISPATCHING itself buys.  Here the question is what happens at
# the handover: ublk_cancel_dev() makes one pass, so a dispatch that publishes
# UBLK_IO_FLAG_OWNED_BY_SRV after its tag was walked hands the request to a
# server that is already gone, and nothing ends it.  Once the quiesce has
# returned, no tag may be server-owned.
ublk_quiesce_no_handover()
{
	local dev_id
	local fio_pid
	local cycle
	local state

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	# depth 1: the tag in use is nearly always the one between being
	# started and being handed over, which is the window the pass skips
	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=randrw --norandommap --iodepth=1 --bs=4k --numjobs=1 \
		--runtime=$RUNTIME --time_based > /dev/null 2>&1 &
	fio_pid=$!

	for ((cycle = 0; cycle < CYCLES; cycle++)); do
		state=$(__ublk_quiesce_dev "${dev_id}" "QUIESCED")
		if [ "$state" != "QUIESCED" ]; then
			echo "dev ${dev_id} isn't quiesced(${state:-failed})"
			_ublk_dump_dev_state "${dev_id}"
			ERR_CODE=255
			break
		fi

		# only while quiesced: a live server owns tags as a matter of
		# course, so a handover that beat the pass is only readable in
		# the window where no server is there to end it
		if ! _ublk_wait_tag_flag_gone "${dev_id}" OWNED_BY_SRV 30; then
			echo "tag handed over after the cancel pass"
			ERR_CODE=255
			break
		fi

		state=$(_recover_ublk_dev -n "${dev_id}" "$@")
		if [ "$state" != "LIVE" ]; then
			echo "dev ${dev_id} isn't recovered($state)"
			ERR_CODE=255
			break
		fi
	done

	kill -9 $fio_pid > /dev/null 2>&1
	wait $fio_pid > /dev/null 2>&1

	_ublk_del_dev_timeout "${dev_id}" || ERR_CODE=255
}

_create_backfile 0 256M

ublk_quiesce_no_handover -t null -q 1 -d 1 -r 1
ublk_quiesce_no_handover -t loop -q 1 -d 1 -r 1 "${UBLK_BACKFILES[0]}"

if ! _check_dmesg; then
	echo "kernel complained during quiesce and recover"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
