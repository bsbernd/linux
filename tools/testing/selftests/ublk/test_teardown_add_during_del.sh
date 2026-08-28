#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Create a device while an unrelated device is being deleted.
#
# ublk_stop_dev() holds ublk_ctl_mutex across del_gendisk(), so a teardown that
# does not finish blocks every device on the machine and not only its own.
#
# The verdict comes from three places, because a leak shows up in different
# ones: a bounded add that never returns, a server or char device that outlives
# its device, and a driver use count that does not fall back.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
LOOPS=2
RUNTIME=15

_prep_test "teardown" "create a device while another is being deleted"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Every other teardown case creates one device, tears it down, and only then
# moves on, so nothing covers a control command arriving from an unrelated
# process while an abort walk is running.
ublk_run_add_during_del()
{
	local kill_daemon=$1
	local dev_id
	local daemon_pid
	local probe_id
	local fio_pid
	local del_pid
	local base_refs
	shift 1

	base_refs=$(_ublk_module_refs)

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?
	daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

	probe_id=$(_ublk_find_free_id)
	if [ -z "$probe_id" ]; then
		echo "no free ublk id to probe with"
		ERR_CODE=255
		return
	fi

	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=write --norandommap --iodepth=64 --bs=1M --numjobs=4 \
		--runtime=$RUNTIME --time_based > /dev/null 2>&1 &
	fio_pid=$!

	sleep 0.$((RANDOM % 9 + 1))

	# delete in the background, so the probe add lands while the abort
	# walk is still running
	_ublk_del_dev_timeout "${dev_id}" &
	del_pid=$!

	# a signal delivered during the abort walk, which is how the server
	# became unkillable when this was first hit
	[ "$kill_daemon" == "1" ] && kill -9 "${daemon_pid}" > /dev/null 2>&1

	_ublk_probe_add_blocked "${probe_id}" "${dev_id}" || ERR_CODE=255

	wait $del_pid || ERR_CODE=255
	_ublk_wait_fio "$fio_pid" $((RUNTIME + 60)) || ERR_CODE=255
	_ublk_wait_daemon_gone "${daemon_pid}" 30 || ERR_CODE=255

	if [ -e "/dev/ublkc${dev_id}" ]; then
		echo "/dev/ublkc${dev_id} outlived its device"
		ERR_CODE=255
	fi

	# a leak shows up here even when everything above returned
	if [ "$(_ublk_module_refs)" != "$base_refs" ]; then
		echo "ublk_drv use count $(_ublk_module_refs), was ${base_refs}"
		ERR_CODE=255
	fi
}

_create_backfile 0 1G

# large writes to a backing file keep requests with the server, so the
# delete has the most to wait on when the add arrives
for ((loop = 0; loop < LOOPS; loop++)); do
	for kill in 0 1; do
		ublk_run_add_during_del $kill -t loop -q 2 -d 64 \
			"${UBLK_BACKFILES[0]}"
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
