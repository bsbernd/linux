#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Release an auto registered buffer on the server task while STOP_DEV drops
# the dispatch reference of the same tag.
#
# __ublk_fail_req() subtracts UBLK_REFCOUNT_INIT - task_registered_buffers
# from the request reference, off the server task. ublk_io_release() on the
# server task decrements task_registered_buffers instead of the reference.
# When the decrement lands between the read and the clear in
# ublk_sub_req_ref(), the reference stays at 1 with no holder: del_gendisk()
# waits for ever.
#
# --hold_io_on_signal holds the read; delay_sub_req_ref holds STOP_DEV after
# the read; SIGUSR2 makes the server commit, the commit is refused and
# unregisters the buffer inside that window. Judged by del_gendisk()
# returning.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
# the refused commit has this long to land inside ublk_sub_req_ref()
SUB_DELAY_US=$((3000000 * UBLK_WAIT_SCALE))
DEPTH=4
ABORT_RES=-19
DEV_ARGS="-t null -q 1 -d ${DEPTH} --auto_zc --hold_io_on_signal --no_auto_part_scan"

_prep_test "teardown" "auto registered buffer released inside the STOP_DEV reference drop"

if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi
if ! _have_feature "AUTO_BUF_REG"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Not judged. Killing the server tears down its ring; without the fix the
# lost reference keeps STOP_DEV and the module for good.
_teardown()
{
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
}

dev_id=$(_add_ublk_dev $DEV_ARGS)
_check_add_dev "$TID" $?
server_pid=$(_get_ublk_daemon_pid "${dev_id}")
if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/delay_sub_req_ref" ]; then
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

# armed only now: no commit runs while the server holds the read, so only
# STOP_DEV takes it
_ublk_arm_delay_point "${dev_id}" delay_sub_req_ref "$SUB_DELAY_US"
_ublk_stop_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
stop_pid=$!
if [ "$ERR_CODE" -eq 0 ] &&
		! _ublk_wait_delay_point_fired "${dev_id}" delay_sub_req_ref "$WAIT_SECS"; then
	echo "setup: STOP_DEV did not reach ublk_sub_req_ref() within ${WAIT_SECS}s"
	ERR_CODE=255
fi

kill -USR2 "$server_pid"
if [ "$ERR_CODE" -eq 0 ]; then
	if ! res=$(_ublk_wait_commit_refused_res "${dev_id}" "$tag" "$WAIT_SECS"); then
		echo "setup: no refused COMMIT_AND_FETCH_REQ on tag ${tag} within ${WAIT_SECS}s"
		ERR_CODE=255
	elif [ "$res" -ne "$ABORT_RES" ]; then
		echo "setup: COMMIT_AND_FETCH_REQ on tag ${tag} got ${res}, not ${ABORT_RES}"
		ERR_CODE=255
	fi
fi

# The buffer release ran before kublk logged the refusal. STOP_DEV still
# inside the delay leaves the tag started with more than its final reference.
if [ "$ERR_CODE" -eq 0 ]; then
	ref=$(_ublk_started_tag_value "${dev_id}" "$tag" ref)
	if [ -z "$ref" ] || [ "$ref" -le 1 ]; then
		echo "setup: the buffer release missed the delay (tag ${tag} ref '${ref}')"
		_teardown
		_cleanup_test
		exit "$UBLK_SKIP_CODE"
	fi
fi

if [ "$ERR_CODE" -eq 0 ] && ! _ublk_wait_disk_detached "${dev_id}" "$WAIT_SECS"; then
	echo "del_gendisk() of dev ${dev_id} wedged: tag ${tag} ref" \
		"$(_ublk_started_tag_value "${dev_id}" "$tag" ref) reg_bufs" \
		"$(_ublk_started_tag_value "${dev_id}" "$tag" reg_bufs)"
	dmesg | grep "ublk_warn_started_rq: dev ${dev_id} " | tail -1
	_ublk_dump_dev_state "${dev_id}"
	ERR_CODE=255
fi
# printed before the teardown below, which may not end
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

_teardown
if ! _check_dmesg; then
	echo "kernel complained during the stop"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
