#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Quiesce a device while a dispatch gives up before the handover.
#
# ublk_ctrl_quiesce_dev() makes a single cancel pass and skips every tag whose
# request is started, which is safe only when the dispatch reaches the
# handover. Three exits never do, and the server is then left waiting for a
# fetch command nobody completes.
#
# Depth one on a single queue with no ramp-up keeps nearly every tag in the
# interval between being started and being handed over.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
CYCLES=6
RUNTIME=40

_prep_test "teardown" "quiesce landing in an abandoned dispatch"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

ublk_run_quiesce_dispatch()
{
	local dev_id
	local fio_pid
	local cycle

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	# depth 1 on few queues: at any moment nearly every tag in use is the
	# one between being started and being handed over, which is the state
	# ublk_ctrl_quiesce_dev() makes a single cancel pass over
	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=randrw --norandommap --iodepth=1 --bs=4k --numjobs=1 \
		--runtime=$RUNTIME --time_based > /dev/null 2>&1 &
	fio_pid=$!

	for ((cycle = 0; cycle < CYCLES; cycle++)); do
		# no ramp-up: the quiesce is sent while the queue is still
		# filling, so it lands on a dispatch rather than on idle tags
		if ! _ublk_quiesce_and_recover "${dev_id}" "$@"; then
			ERR_CODE=255
			break
		fi
	done

	kill -9 $fio_pid > /dev/null 2>&1
	wait $fio_pid > /dev/null 2>&1

	_ublk_del_dev_timeout "${dev_id}" || ERR_CODE=255
}

_create_backfile 0 256M

ublk_run_quiesce_dispatch -t null -q 1 -d 1 -r 1
ublk_run_quiesce_dispatch -t loop -q 1 -d 1 -r 1 "${UBLK_BACKFILES[0]}"

if _have_feature "AUTO_BUF_REG"; then
	# ublk_auto_buf_dispatch() gives up when the buffer cannot be
	# registered and no fallback was asked for, which is the third exit
	# that reaches no handover. Registration succeeds on its own, so
	# --bad_buf_index is what makes that exit reachable: without it this
	# arm only exercises the path where the buffer registers fine.
	ublk_run_quiesce_dispatch -t null -q 1 -d 4 -r 1 --auto_zc \
		--bad_buf_index
	ublk_run_quiesce_dispatch -t loop -q 1 -d 4 -r 1 --auto_zc \
		"${UBLK_BACKFILES[0]}"
fi

if ! _check_dmesg; then
	echo "kernel complained during quiesce and recover"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
