#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Delete a device while a dispatch is held, so that the request is handed over
# to the server after STOP_DEV's pass over the started requests.
#
# delay_dispatch holds the dispatch of one read until STOP_DEV has set
# ->canceling, passed over the tags and waits in del_gendisk(). The pass ends
# only requests owned by the server, and this one is not yet. A handover after
# the pass gives the request to a server that holds it, so del_gendisk() waits
# for ever unless ->canceling refuses the handover.
#
# Judged by del_gendisk() returning, not by the delete: a request the server
# held before ->canceling keeps it running, and the delete waits for its exit.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
# STOP_DEV reaches del_gendisk() within milliseconds of the delete; a handover
# before ->canceling is set would end in the pass instead
DISPATCH_DELAY_US=3000000
# no -r: a refused request is ended, not requeued
DEV_ARGS="-t null -q 1 -d 4 --hold_io_on_signal --no_auto_part_scan"

_prep_test "teardown" "hand a request over after the pass of STOP_DEV"

if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Usage: _arm_delay_point <dev_id> <name> <delay_us>
_arm_delay_point()
{
	local dir=${DEBUGFS_ROOT}/$1/$2

	echo 0 > "${dir}/verbose"
	echo 100 > "${dir}/probability"
	echo 1 > "${dir}/times"
	echo "$3" > "${dir}/delay_us"
}

del_dev()
{
	"${UBLK_PROG}" del -n "$1"
}

dev_id=$(_add_ublk_dev $DEV_ARGS)
_check_add_dev "$TID" $?

if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/delay_dispatch" ]; then
	echo "no delay points (CONFIG_FAULT_INJECTION_DEBUG_FS)"
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi
server_pid=$(_get_ublk_daemon_pid "${dev_id}")

# armed only once the reads udev issued at add were served
if ! _ublk_wait_no_inflight "${dev_id}" "$WAIT_SECS"; then
	echo "IO from the add still in flight after ${WAIT_SECS}s"
	ERR_CODE=255
fi
kill -USR1 "$server_pid"

_arm_delay_point "${dev_id}" delay_dispatch "$DISPATCH_DELAY_US"
_ublk_read_one_block "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
dd_pid=$!
if ! _ublk_wait_delay_point_fired "${dev_id}" delay_dispatch "$WAIT_SECS"; then
	echo "the read was not dispatched within ${WAIT_SECS}s"
	ERR_CODE=255
fi

del_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
del_pid=$!
if [ "$ERR_CODE" -eq 0 ] && ! _ublk_wait_disk_detached "${dev_id}" "$WAIT_SECS"; then
	echo "del_gendisk() of dev ${dev_id} wedged: the read was handed to the server"
	ps -eo pid,stat,wchan:32,args | grep -E "[k]ublk|[d]d if="
	_ublk_dump_dev_state "${dev_id}"
	ERR_CODE=255
fi
# printed before the teardown below, which may not end
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

# Not judged. Killing the server releases the device, which ends the
# request the server owns, and lets the delete stop waiting for its exit.
if ! _ublk_wait_pid_gone "$del_pid" 5; then
	kill -9 "$server_pid"
	if ! _ublk_wait_pid_gone "$del_pid" "$WAIT_SECS"; then
		echo "delete dev ${dev_id} still wedged after killing the server"
	fi
fi
if ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
	echo "the read still in flight after ${WAIT_SECS}s"
fi
sed -i "/^${dev_id}$/d" "${UBLK_TEST_DIR}/.ublk_devs"
if ! _check_dmesg; then
	echo "kernel complained during the delete"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
