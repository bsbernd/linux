#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Send one more FETCH_REQ from a server thread while STOP_DEV waits for a read
# whose auto registered buffer only that thread can release.
#
# STOP_DEV holds ub->mutex across del_gendisk(), which waits for the read. The
# read keeps the reference of its auto registered buffer, and only a commit or
# the teardown of the server's ring drops it. If the FETCH_REQ sleeps on
# ub->mutex, the server thread can do neither, and kill -9 cannot end it:
# kublk, STOP_DEV and the read hang in D state.
#
# A hang cannot be cleaned up from here, so on that path the test reports and
# exits, leaving the device behind.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
EBUSY=16
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
DEPTH=4

_prep_test "teardown" "FETCH_REQ while STOP_DEV waits for an auto registered buffer"

if ! _have_feature "NO_AUTO_PART_SCAN" || ! _have_feature "AUTO_BUF_REG"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# without the stop_dev step there is no telling that STOP_DEV holds ub->mutex
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Wait for a line kublk wrote to the kernel log after this test started.
# Polled in tenths: from the stop_dev step on, the read has to end within the
# 5 s of ublk_warn_started_rqs().
# Usage: _wait_kmsg <text> <deadline>
_wait_kmsg()
{
	local text=$1
	local deadline=$2
	local from
	local tenths=0

	from=$(dmesg | grep -n "ublk selftest: ${TID} starting" | tail -1 |
		cut -d: -f1)
	while [ "$tenths" -lt $((deadline * 10)) ]; do
		if dmesg | tail -n +$((from + 1)) | grep -q "$text"; then
			return 0
		fi
		sleep 0.1
		tenths=$((tenths + 1))
	done
	return 1
}

# Wait for a held read: started, owned by the server, buffer registered.
# Usage: _wait_held_tag <dev_id>
_wait_held_tag()
{
	local tenths=0
	local flags
	local tag

	while [ "$tenths" -lt $((WAIT_SECS * 10)) ]; do
		for ((tag = 0; tag < DEPTH; tag++)); do
			flags=$(_ublk_started_tag_flags "$1" "$tag")
			if [[ "$flags" == *OWNED_BY_SRV* && "$flags" == *AUTO_BUF_REG* ]]; then
				return 0
			fi
		done
		sleep 0.1
		tenths=$((tenths + 1))
	done
	return 1
}

# The driver records the stop_dev step under ub->mutex, before
# del_gendisk(), and keeps the mutex until del_gendisk() returns.
_wait_stop_dev_step()
{
	local dev_id=$1
	local tenths=0

	while [ "$tenths" -lt $((WAIT_SECS * 10)) ]; do
		if grep -q "^steps:.* stop_dev" "${DEBUGFS_ROOT}/${dev_id}/teardown"; then
			return 0
		fi
		sleep 0.1
		tenths=$((tenths + 1))
	done
	return 1
}

# Before SIGUSR2 nothing is stuck yet: killing the server ends its ring, which
# releases the buffer, and the read, STOP_DEV and the device can go.
_fail_and_cleanup()
{
	echo "$1"
	echo "verdict: fail"
	kill -9 "$daemon_pid"
	_cleanup_test
	_show_result $TID 255
}

# no settle: udev's probe read is held like ours and would never end
dev_id=$(_add_ublk_dev_no_settle -t null -q 1 -d "$DEPTH" --no_auto_part_scan \
	--auto_zc --hold_io --refetch_on_signal)
_check_add_dev "$TID" $?
daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

# no fd of ours: a dd stuck in D state must not hold the caller's pipe open
_ublk_read_one_block "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
dd_pid=$!
if ! _wait_held_tag "${dev_id}"; then
	_fail_and_cleanup "no read held with an auto registered buffer within ${WAIT_SECS}s"
fi

kill -USR1 "$daemon_pid"
if ! _wait_kmsg "kublk: dev ${dev_id} stopped reaping" "$WAIT_SECS"; then
	_fail_and_cleanup "kublk did not stop reaping"
fi

_ublk_stop_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
stop_pid=$!
if ! _wait_stop_dev_step "${dev_id}"; then
	_fail_and_cleanup "STOP_DEV never took ub->mutex"
fi

kill -USR2 "$daemon_pid"

# Without the fix the FETCH_REQ sleeps on ub->mutex for ever: kublk, STOP_DEV
# and dd stay in D state and nothing here can end them.
if ! _wait_kmsg "kublk: dev ${dev_id} FETCH_REQ on tag 0: res -${EBUSY}$" \
		"$WAIT_SECS"; then
	echo "FETCH_REQ not refused with -EBUSY within ${WAIT_SECS}s"
	ps -eLo pid,tid,stat,wchan:32,args | grep -E "[k]ublk|[d]d if="
	cat "${DEBUGFS_ROOT}/${dev_id}/teardown"
	echo "verdict: fail"
	_show_result $TID 255
fi

# the refused FETCH_REQ left the read held; the ring teardown of the killed
# server releases its buffer
kill -9 "$daemon_pid"
if ! _ublk_wait_disk_detached "${dev_id}" "$WAIT_SECS"; then
	echo "del_gendisk() of dev ${dev_id} did not return after killing the server"
	ps -eLo pid,tid,stat,wchan:32,args | grep -E "[k]ublk|[d]d if="
	ERR_CODE=255
fi
# printed before the teardown below, which may not end
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

if ! _ublk_wait_pid_gone "$stop_pid" "$WAIT_SECS"; then
	echo "STOP_DEV did not return within ${WAIT_SECS}s"
	_show_result $TID 255
fi
if ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
	echo "the read did not end within ${WAIT_SECS}s"
	_show_result $TID 255
fi

if ! _ublk_del_dev_timeout "${dev_id}"; then
	ERR_CODE=255
fi

if ! _check_dmesg; then
	echo "kernel complained during STOP_DEV"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
