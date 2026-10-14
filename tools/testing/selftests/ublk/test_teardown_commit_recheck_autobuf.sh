#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Stop a device while the server's commit of a request with an auto registered
# buffer sits between its two UBLK_IO_FLAG_OWNED_BY_SRV tests.
#
# The commit passes the unlocked test, then the delay point holds it. STOP_DEV
# takes the tag meanwhile: ublk_abort_dev() clears OWNED_BY_SRV and the request
# keeps the reference of its buffer. The locked re-test then refuses the commit
# with UBLK_IO_RES_ABORT (-ENODEV). Unless that refusal unregisters the buffer
# nothing drops the reference while the server lives: del_gendisk() waits.
#
# Judged by del_gendisk() returning and by ublk_warn_started_rq() staying quiet.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
DEPTH=4
ABORT_RES=-19
# STOP_DEV has this long to take the tag; below the 5 s of ublk_warn_started_rqs()
COMMIT_DELAY_US=2000000
DEV_ARGS="-t null -q 1 -d ${DEPTH} --auto_zc --hold_io_on_signal --no_auto_part_scan"

_prep_test "teardown" "STOP_DEV takes an auto registered tag between the commit's tests"

if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi
if ! _have_feature "AUTO_BUF_REG"; then
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

dev_id=$(_add_ublk_dev $DEV_ARGS)
_check_add_dev "$TID" $?
server_pid=$(_get_ublk_daemon_pid "${dev_id}")

if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/delay_commit_recheck" ]; then
	echo "no delay points (CONFIG_FAULT_INJECTION_DEBUG_FS)"
	_ublk_del_dev_timeout "${dev_id}"
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# armed only once the reads udev issued at add were served
if ! _ublk_wait_no_inflight "${dev_id}" "$WAIT_SECS"; then
	echo "IO from the add still in flight after ${WAIT_SECS}s"
	ERR_CODE=255
fi
kill -USR1 "$server_pid"

_ublk_read_one_block "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
dd_pid=$!
tag=-1
if [ "$ERR_CODE" -eq 0 ] && ! tag=$(_ublk_wait_held_tag "${dev_id}" "$DEPTH" "$WAIT_SECS"); then
	echo "setup: no read held with an auto registered buffer within ${WAIT_SECS}s"
	ERR_CODE=255
fi

# the held commit is the only COMMIT_AND_FETCH_REQ until SIGUSR2
_arm_delay_point "${dev_id}" delay_commit_recheck "$COMMIT_DELAY_US"
kill -USR2 "$server_pid"
# fired: the commit passed the unlocked OWNED_BY_SRV test before STOP_DEV
if [ "$ERR_CODE" -eq 0 ] &&
		! _ublk_wait_delay_point_fired "${dev_id}" delay_commit_recheck "$WAIT_SECS"; then
	echo "setup: the commit of tag ${tag} did not reach the delay point within ${WAIT_SECS}s"
	ERR_CODE=255
fi

_ublk_stop_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
stop_pid=$!
# refused: STOP_DEV took the tag before the locked re-test
if [ "$ERR_CODE" -eq 0 ]; then
	if ! res=$(_ublk_wait_commit_refused_res "${dev_id}" "$tag" "$WAIT_SECS"); then
		echo "setup: no refused COMMIT_AND_FETCH_REQ on tag ${tag} within ${WAIT_SECS}s"
		ERR_CODE=255
	elif [ "$res" -ne "$ABORT_RES" ]; then
		echo "setup: COMMIT_AND_FETCH_REQ on tag ${tag} got ${res}, not ${ABORT_RES}"
		ERR_CODE=255
	fi
fi
if [ "$ERR_CODE" -eq 0 ] && ! _ublk_wait_disk_detached "${dev_id}" "$WAIT_SECS"; then
	echo "del_gendisk() of dev ${dev_id} wedged: the re-test left the buffer registered"
	ps -eo pid,stat,wchan:32,args | grep -E "[k]ublk|[d]d if="
	_ublk_dump_dev_state "${dev_id}"
	ERR_CODE=255
fi
if [ "$ERR_CODE" -eq 0 ] && ! _check_dmesg; then
	echo "STOP_DEV found a request it had not disposed of"
	ERR_CODE=255
fi
# printed before the teardown below, which may not end
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

# Not judged. Killing the server tears down its ring, which unregisters the
# buffer and lets STOP_DEV return.
if ! _ublk_wait_pid_gone "$stop_pid" 5; then
	kill -9 "$server_pid"
	if ! _ublk_wait_pid_gone "$stop_pid" "$WAIT_SECS"; then
		echo "stop dev ${dev_id} still wedged after killing the server"
	fi
fi
if ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
	echo "the read still in flight after ${WAIT_SECS}s"
fi
_ublk_del_dev_timeout "${dev_id}"
if ! _check_dmesg; then
	echo "kernel complained during the stop"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
