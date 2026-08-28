#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Quiesce repeatedly while the server keeps parking commands.
#
# QUIESCE_DEV leaves the server live, so it can park a command on a tag
# ublk_cancel_queue() has already visited, and that pass never comes back. fio
# drives the queue throughout so each quiesce lands at a different point.
#
# The failure is one that never returns, so both the quiesce and the delete are
# bounded.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
CYCLES=4
RUNTIME=30

_prep_test "teardown" "quiesce with the server returning commands"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

_create_backfile 0 256M

_ublk_run_quiesce_cycles "$CYCLES" "$RUNTIME" -t null -q 4 -d 128 -r 1 ||
	ERR_CODE=255
_ublk_run_quiesce_cycles "$CYCLES" "$RUNTIME" -t loop -q 2 -d 64 -r 1 \
	"${UBLK_BACKFILES[0]}" || ERR_CODE=255

if ! _check_dmesg; then
	echo "kernel complained during quiesce and recover"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
