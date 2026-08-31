#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Quiesce a UBLK_F_BATCH_IO device.
#
# ublk_wait_for_idle_io() returns immediately for batch mode, so QUIESCE_DEV
# runs its single cancel pass against whatever the queues hold at that moment,
# and the server learns about the quiesce only if an fcmd was cancellable
# there. Every other quiesce case creates a non-batch device, so neither that
# early return nor ublk_batch_cancel_queue() behind it was covered.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
CYCLES=4
RUNTIME=30

_prep_test "teardown" "quiesce a batch device"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _have_feature "BATCH_IO"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

_create_backfile 0 256M

# ublk_wait_for_idle_io() returns at once for UBLK_F_BATCH_IO, so the cancel
# pass runs against whatever the queues hold at that instant and the server
# hears about the quiesce only if an fcmd was cancellable. Deep queues keep
# events on evts_fifo while that happens.
_ublk_run_quiesce_cycles "$CYCLES" "$RUNTIME" -t null -q 2 -d 256 -b -r 1 ||
	ERR_CODE=255
_ublk_run_quiesce_cycles "$CYCLES" "$RUNTIME" -t loop -q 2 -d 256 -b -r 1 \
	"${UBLK_BACKFILES[0]}" || ERR_CODE=255

if ! _check_dmesg; then
	echo "kernel complained during batch quiesce"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
