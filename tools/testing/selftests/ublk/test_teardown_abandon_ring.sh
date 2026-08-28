#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Kill a server that left its io_uring rings while requests sit on
# ubq->disp_list.
#
# Those requests are reachable only from the task work armed on the tag's
# command, so the one cancel mode run is the only chance they get. A run that
# dispatches instead of giving them back leaves them started, del_gendisk()
# waits for them, and ublk_stop_dev() holds ublk_ctl_mutex across that wait.
#
# --abandon_ring closes the rings but keeps /dev/ublkcN open and parks in
# pause(), so the server has to be killed from outside, before the delete.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
LOOPS=2
RUNTIME=15

_prep_test "teardown" "server leaving its rings live"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

_create_backfile 0 512M

# The classic dispatch path queues its requests on the per-queue list and
# hands the tag's command to task work. When the ring goes away that task
# work runs once with cancel set, and it is the only chance the requests on
# the list get: nothing else can reach them, so a run that dispatches
# instead of giving them back leaves them started for ever.
for ((loop = 0; loop < LOOPS; loop++)); do
	for sig in INT TERM; do
		_ublk_run_signal_teardown $sig 1M write 4 $RUNTIME \
			-t loop -q 2 -d 64 --abandon_ring \
			"${UBLK_BACKFILES[0]}" || ERR_CODE=255

		# several queues and several tasks, so a request can be on a
		# list its own task work is not the one to drain
		_ublk_run_signal_teardown $sig 4k randrw 4 $RUNTIME \
			-t null -q 4 -d 128 --nthreads 8 --per_io_tasks \
			--abandon_ring || ERR_CODE=255

		_ublk_run_signal_teardown $sig 4k randrw 4 $RUNTIME \
			-t null -q 4 -d 128 -r 1 --abandon_ring || ERR_CODE=255
	done
done

if ! _check_dmesg; then
	echo "kernel complained after the server left its rings"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
