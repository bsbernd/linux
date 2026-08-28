#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Land a delete while the server is still installing commands.
#
# ublk_cancel_cmd() runs from io_uring's cancel_fn while the server can still
# install a command, so testing io->flags and claiming the cmd/req union has to
# be one step. The delete is bounded and its landing point varied; a race that
# completes leaves only a kernel log line, so that is read as well.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
LOOPS=2
RUNTIME=10

_prep_test "teardown" "cancellation racing a command install"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# a null target completes at once, so every tag is committing a result and
# fetching again for as long as fio runs -- which is what the delete has to
# land in the middle of
for ((loop = 0; loop < LOOPS; loop++)); do
	_ublk_run_del_mid_io 4k randrw 4 $RUNTIME -t null -q 8 -d 128 ||
		ERR_CODE=255
	_ublk_run_del_mid_io 4k randrw 4 $RUNTIME -t null -q 8 -d 128 \
		--nthreads 8 --per_io_tasks || ERR_CODE=255
done

if ! _check_dmesg; then
	echo "kernel complained during teardown"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
