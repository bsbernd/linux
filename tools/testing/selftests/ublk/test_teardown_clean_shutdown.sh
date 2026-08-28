#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Have a server stop its own device while its queues are still live.
#
# Every other teardown case deletes from an unrelated process, so the stop
# always arrives from outside. A real server picks the other ordering: it tells
# the driver first and leaves its rings only once the queues drained.
#
# The device is expected to go without any help -- the server exits on its own,
# an add from another process does not queue behind it, and the delete that
# follows does not wait.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
LOOPS=2
RUNTIME=15

_prep_test "teardown" "server stopping its own device"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# The other cases all delete the device from an unrelated process, so the
# stop always arrives from outside. A server that stops its own device while
# its queues are still live is a different ordering: it tells the driver
# first and leaves its rings only once the queues drained.
ublk_run_clean_shutdown()
{
	local sig=$1
	local dev_id
	local daemon_pid
	local probe_id
	local fio_pid
	shift 1

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?
	daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")
	probe_id=$(_ublk_find_free_id)

	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=write --norandommap --iodepth=64 --bs=1M --numjobs=4 \
		--runtime=$RUNTIME --time_based > /dev/null 2>&1 &
	fio_pid=$!

	sleep 0.$((RANDOM % 9 + 1))
	kill -"$sig" "${daemon_pid}" > /dev/null 2>&1

	# the device is expected to go without any help, and an unrelated
	# add must not queue behind it
	[ -n "$probe_id" ] &&
		{ _ublk_probe_add_blocked "${probe_id}" "${dev_id}" ||
			ERR_CODE=255; }

	_ublk_wait_daemon_exit "${daemon_pid}" 30 || ERR_CODE=255
	_ublk_wait_fio "$fio_pid" $((RUNTIME + 60)) || ERR_CODE=255

	# STOP_DEV leaves the device present but dead, so it still needs a
	# delete -- what must not happen is that the delete has to wait
	_ublk_del_dev_timeout "${dev_id}" > /dev/null 2>&1
}

_create_backfile 0 1G

for ((loop = 0; loop < LOOPS; loop++)); do
	for sig in INT TERM; do
		ublk_run_clean_shutdown $sig -t loop -q 2 -d 64 \
			--clean_teardown "${UBLK_BACKFILES[0]}"
		ublk_run_clean_shutdown $sig -t null -q 4 -d 128 \
			--clean_teardown
	done
done

if ! _ublk_check_no_stale_devs; then
	ERR_CODE=255
fi

if ! _check_dmesg; then
	echo "kernel complained during teardown"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
