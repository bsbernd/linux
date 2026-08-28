#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Have a server delete its own device.
#
# Every other delete comes from a process that holds no reference on the
# device, so none of them can wait on themselves. A server that deletes its own
# does: each command it has parked is a reference on its own ublkc file, and
# those only go when it exits, which it cannot do until the delete returns.
#
# The verdict comes from three places, because the failure shows up in
# different ones -- a server that never exits, a /dev/ublkcN that outlives it,
# and a device number the next add cannot have.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
LOOPS=2
RUNTIME=15

_prep_test "teardown" "server deleting its own device"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Every command the server has parked is a reference on its own ublkc file,
# so a delete that waits for the last one waits for the server to exit --
# which it cannot do until the delete returns.
ublk_run_self_del()
{
	local sig=$1
	local dev_id
	local daemon_pid
	local fio_pid
	shift 1

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?
	daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=randrw --norandommap --iodepth=64 --bs=4k --numjobs=4 \
		--runtime=$RUNTIME --time_based > /dev/null 2>&1 &
	fio_pid=$!

	sleep 0.$((RANDOM % 9 + 1))
	kill -"$sig" "${daemon_pid}" > /dev/null 2>&1

	# nobody deletes the device from outside and nothing signals the
	# server again: it has to get through its own delete and exit
	_ublk_wait_daemon_exit "${daemon_pid}" 30 || ERR_CODE=255
	_ublk_wait_fio "$fio_pid" $((RUNTIME + 60)) || ERR_CODE=255

	if [ -e "/dev/ublkc${dev_id}" ]; then
		echo "/dev/ublkc${dev_id} outlived its server"
		ERR_CODE=255
	fi

	# the number has to be free again, or the next add blocks on it
	if ! timeout 30 "${UBLK_PROG}" add -t null -n "${dev_id}" -q 1 -d 8 \
			> /dev/null 2>&1; then
		echo "dev id ${dev_id} could not be reused after self delete"
		ERR_CODE=255
	else
		_ublk_del_dev_timeout "${dev_id}" || ERR_CODE=255
	fi
}

_create_backfile 0 256M

for ((loop = 0; loop < LOOPS; loop++)); do
	for sig in INT TERM; do
		ublk_run_self_del $sig -t null -q 2 -d 64 --self_del
		ublk_run_self_del $sig -t loop -q 2 -d 64 --self_del \
			"${UBLK_BACKFILES[0]}"
	done
done

# each of those deletes should have freed its device outright, so nothing
# should have been parked under stale/ waiting for a reference to go
if ! _ublk_check_no_stale_devs; then
	ERR_CODE=255
fi

if ! _check_dmesg; then
	echo "kernel complained during self delete"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
