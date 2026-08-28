#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Delete a UBLK_F_USER_RECOVERY device with a request requeued after the kick.
#
# A request that finds no server is put on the requeue list without a kick, and
# ublk_force_abort_dev() kicks once. Submitting past the point where the device
# is quiesced lands a request there afterwards; without a second kicker
# del_gendisk() waits for it for ever, so the delete is bounded.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
RUNTIME=60

_prep_test "teardown" "delete a recovery device with requests requeued"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

ublk_run_force_abort()
{
	local dev_id
	local fio_pid
	local state

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=randrw --norandommap --iodepth=64 --bs=4k --numjobs=2 \
		--runtime=$RUNTIME --time_based > /dev/null 2>&1 &
	fio_pid=$!

	sleep 2

	state=$(__ublk_kill_daemon "${dev_id}" "QUIESCED")
	if [ "$state" != "QUIESCED" ]; then
		echo "dev ${dev_id} isn't quiesced($state) after kill"
		ERR_CODE=255
	fi

	# With no server left, a request that finds none is put on the
	# requeue list without a kick. ublk_force_abort_dev() kicks once, so
	# fio has to keep submitting past that point for one to land after it
	# -- and no new server ever attaches to kick again.
	sleep 3

	_ublk_del_dev_timeout "${dev_id}" || ERR_CODE=255
	_ublk_wait_fio "$fio_pid" 60 || ERR_CODE=255
}

_create_backfile 0 256M

ublk_run_force_abort -t null -q 2 -d 64 -r 1
ublk_run_force_abort -t loop -q 2 -d 64 -r 1 "${UBLK_BACKFILES[0]}"
ublk_run_force_abort -t null -q 2 -d 64 -r 1 -i 1

if ! _check_dmesg; then
	echo "kernel complained during teardown"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
