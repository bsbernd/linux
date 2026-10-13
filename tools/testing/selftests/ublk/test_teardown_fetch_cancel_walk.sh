#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Land the STOP_DEV cancel walk inside the io->flags update of a FETCH_REQ.
#
# The device is never started, so tag 0 has no request. One delay point holds
# ublk_cancel_dev() after STOP_DEV dropped ub->mutex, the other holds the
# FETCH_REQ on tag 0 between the load and the store of its io->flags update.
# Unless io->lock covers that update, ublk_cancel_cmd() takes the command in
# between and the store brings back UBLK_IO_FLAG_ACTIVE without a command.
#
# ublk_cancel_cmd() completes that command before ublk_prep_cancel() marks it,
# with io->lock or without, so the teardown after the check may wedge. Only the
# tag state decides the result.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
# the FETCH_REQ has this long to reach its delay point after STOP_DEV unlocks
CANCEL_DELAY_US=3000000
# with io->lock this spins with the lock held: keep it far below the soft
# lockup limit
FILL_DELAY_US=6000000

_prep_test "teardown" "FETCH_REQ io->flags update against the STOP_DEV cancel walk"

if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# The driver records the stop_dev step under ub->mutex, before the delayed
# walk. Polled in tenths: the FETCH_REQ has to follow within CANCEL_DELAY_US.
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

# Usage: _arm_delay_point <dev_id> <name> <delay_us>
_arm_delay_point()
{
	local dir=${DEBUGFS_ROOT}/$1/$2

	echo 0 > "${dir}/verbose"
	echo 100 > "${dir}/probability"
	echo 1 > "${dir}/times"
	echo "$3" > "${dir}/delay_us"
}

# exec: the PID of the background job is then kublk itself, which takes the
# signals
start_server()
{
	exec "${UBLK_PROG}" add -n "$1" -t null -q 1 -d 4 --foreground \
		--refetch_on_signal --refetch_unready
}

del_dev()
{
	"${UBLK_PROG}" del -n "$1"
}

# Before SIGUSR2 nothing has raced yet: the server and the device can go.
# Usage: _end_early <message> <exit code>
_end_early()
{
	echo "$1"
	kill -9 "$daemon_pid"
	_ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"
	_ublk_del_dev_timeout "$dev_id"
	_cleanup_test
	_show_result $TID "$2"
}

dev_id=$(_ublk_free_dev_id)
# no fd of ours: a server stuck in exit must not hold the caller's pipe open
start_server "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
daemon_pid=$!

# Tags 2 and 3 parked: the IO thread runs and takes SIGUSR1.
if ! _ublk_wait_tags_parked "${dev_id}" 2 "$WAIT_SECS"; then
	_end_early "kublk did not fetch tags 2 and 3" 255
fi
if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/delay_fill_io_cmd" ]; then
	_end_early "no delay points (CONFIG_FAULT_INJECTION_DEBUG_FS)" \
		"$UBLK_SKIP_CODE"
fi
_arm_delay_point "${dev_id}" delay_cancel_dev "$CANCEL_DELAY_US"
_arm_delay_point "${dev_id}" delay_fill_io_cmd "$FILL_DELAY_US"

kill -USR1 "$daemon_pid"
if ! _ublk_wait_kmsg "kublk: dev ${dev_id} stopped reaping" "$WAIT_SECS"; then
	_end_early "kublk did not stop reaping" 255
fi

_ublk_stop_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
stop_pid=$!
if ! _wait_stop_dev_step "${dev_id}"; then
	_end_early "STOP_DEV did not reach ublk_stop_dev()" 255
fi

kill -USR2 "$daemon_pid"

if ! _ublk_wait_kmsg "kublk: dev ${dev_id} FETCH_REQ on tag 0 returned" \
		"$WAIT_SECS"; then
	echo "FETCH_REQ on tag 0 did not return within ${WAIT_SECS}s"
	_show_result $TID 255
fi
if ! _ublk_wait_pid_gone "$stop_pid" "$WAIT_SECS"; then
	echo "STOP_DEV did not return within ${WAIT_SECS}s"
	_show_result $TID 255
fi

tag0=$(_ublk_tag_lines "${dev_id}" 0)
echo "tag 0 after STOP_DEV and the FETCH_REQ:"
echo "$tag0"
if ! _ublk_delay_point_fired "${dev_id}" delay_cancel_dev ||
		! _ublk_delay_point_fired "${dev_id}" delay_fill_io_cmd; then
	echo "a delay point did not fire"
	ERR_CODE=255
elif echo "$tag0" | grep -q CMD_PARKED; then
	echo "the cancel walk reached tag 0 outside the io->flags update"
	ERR_CODE=255
elif echo "$tag0" | grep -q "ACTIVE "; then
	echo "UBLK_IO_FLAG_CANCELED lost: tag 0 ACTIVE without a command"
	ERR_CODE=255
fi
# printed before the teardown below, which may not end
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

# Not judged: the completed FETCH_REQ is still marked cancelable either way.
kill -9 "$daemon_pid"
if ! _ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"; then
	echo "kublk still exiting after ${WAIT_SECS}s"
fi
del_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
del_pid=$!
if ! _ublk_wait_pid_gone "$del_pid" "$WAIT_SECS"; then
	echo "DEL_DEV did not return within ${WAIT_SECS}s"
fi
if ! _check_dmesg; then
	echo "kernel complained after the check"
fi

_cleanup_test
_show_result $TID $ERR_CODE
