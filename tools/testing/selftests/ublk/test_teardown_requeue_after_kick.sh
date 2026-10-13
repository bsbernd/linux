#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Delete a recovering device while a dispatch is held, so that its request is
# requeued after the last kick of the requeue list.
#
# A second server fetches, but never ends the recovery, so the device stays
# QUIESCED with a live server. delay_dispatch holds the dispatch of one write
# until STOP_DEV has set force_abort, kicked the requeue list, set ->canceling
# and waits in del_gendisk(). The server then refuses the request, and it is
# requeued without a kick unless force_abort brings one.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
# STOP_DEV reaches del_gendisk() within milliseconds of the delete
DISPATCH_DELAY_US=1000000
DEV_ARGS="-t null -q 1 -d 2 -r 1"

_prep_test "teardown" "requeue a request after the last kick of STOP_DEV"

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

# The server fetched every tag and the device-level ->canceling is clear,
# so a new request is dispatched to it.
# Usage: _wait_server_ready <dev_id>
_wait_server_ready()
{
	local dev_state=${DEBUGFS_ROOT}/$1/dev_state
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if grep -q "^canceling: 0" "$dev_state" &&
				grep -q "nr_io_ready 2$" "$dev_state"; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
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

state=$(__ublk_kill_daemon "${dev_id}" "QUIESCED")
if [ "$state" != "QUIESCED" ]; then
	echo "dev ${dev_id} isn't quiesced($state) after kill"
	_cleanup_test
	_show_result $TID 255
fi

if ! "${UBLK_PROG}" recover -n "${dev_id}" $DEV_ARGS --no_end_recovery \
		> /dev/null; then
	echo "recover of dev ${dev_id} failed"
	_cleanup_test
	_show_result $TID 255
fi
if ! _wait_server_ready "${dev_id}"; then
	echo "the new server of dev ${dev_id} did not fetch every tag"
	_ublk_dump_dev_state "${dev_id}"
	_cleanup_test
	_show_result $TID 255
fi
server_pid=$(awk '$1 == "ublksrv_tgid:" { print $2 }' \
	"${DEBUGFS_ROOT}/${dev_id}/dev_state")

_arm_delay_point "${dev_id}" delay_dispatch "$DISPATCH_DELAY_US"
_ublk_write_one_block "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
dd_pid=$!
if ! _ublk_wait_delay_point_fired "${dev_id}" delay_dispatch "$WAIT_SECS"; then
	echo "the write was not dispatched within ${WAIT_SECS}s"
	ERR_CODE=255
fi

del_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
del_pid=$!
if [ "$ERR_CODE" -eq 0 ] && ! _ublk_wait_pid_gone "$del_pid" "$WAIT_SECS"; then
	echo "delete dev ${dev_id} wedged: the requeued write was never kicked"
	ERR_CODE=255
fi
# printed before the teardown below, which may not end
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

# Not judged. The killed server cancels its commands, and its release work
# kicks the requeue list again.
if kill -0 "$del_pid" 2>/dev/null; then
	kill -9 "$server_pid"
	if ! _ublk_wait_pid_gone "$del_pid" "$WAIT_SECS"; then
		echo "delete dev ${dev_id} still wedged after killing the server"
	fi
fi
if ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
	echo "the write still in flight after ${WAIT_SECS}s"
fi
sed -i "/^${dev_id}$/d" "${UBLK_TEST_DIR}/.ublk_devs"
if ! _check_dmesg; then
	echo "kernel complained during the delete"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
