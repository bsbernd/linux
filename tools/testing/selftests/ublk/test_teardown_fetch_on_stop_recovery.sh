#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Send FETCH_REQ during user recovery while STOP_DEV waits for the server.
#
# One server thread serves both queues. Queue 0 is ready, so the read below is
# dispatched to that thread as task work; queue 1 is not, so its FETCH_REQs
# pass the ready test and take ub->mutex. STOP_DEV holds ub->mutex across
# del_gendisk(), which waits for the read: unless STOP_DEV ends the read first,
# the server thread, STOP_DEV and the read hang in D state.
#
# A hang cannot be cleaned up from here, so on that path the test reports and
# exits, leaving the device behind.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))

_prep_test "teardown" "FETCH_REQ during user recovery while STOP_DEV runs"

if ! _have_feature "PER_IO_DAEMON"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# without dev_state and the stop_dev step there is no telling where we are
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# The driver clears ->canceling of a queue once all its tags are fetched.
_wait_queue_ready()
{
	local dev_id=$1
	local q_id=$2
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if grep -q "^queue ${q_id}: .* canceling 0 " \
				"${DEBUGFS_ROOT}/${dev_id}/dev_state"; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

# The driver records the stop_dev step under ub->mutex, right before
# del_gendisk(), and keeps the mutex until del_gendisk() returns.
_wait_stop_dev_step()
{
	local dev_id=$1
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if grep -q "^steps:.* stop_dev" "${DEBUGFS_ROOT}/${dev_id}/teardown"; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

# the read must come from a CPU that maps to queue 0
read_one_block()
{
	taskset -c "$2" dd if=/dev/ublkb"$1" of=/dev/null iflag=direct bs=4k count=1
}

# Before SIGUSR2 nothing is stuck yet: killing the parked server ends its
# rings, which lets the read and STOP_DEV finish, and the device can go.
_fail_and_cleanup()
{
	echo "$1"
	kill -9 "$daemon_pid"
	_cleanup_test
	_show_result $TID 255
}

dev_id=$(_add_ublk_dev -t null -q 2 --nthreads 1 --per_io_tasks -r 1)
_check_add_dev "$TID" $?

state=$(__ublk_kill_daemon "${dev_id}" "QUIESCED")
if [ "$state" != "QUIESCED" ]; then
	echo "device isn't quiesced($state) after killing the server"
	_cleanup_test
	_show_result $TID 255
fi

# --foreground: this process is the server, and END_USER_RECOVERY in it waits
# for queue 1 until SIGUSR2
"${UBLK_PROG}" recover -n "${dev_id}" -t null -q 2 --nthreads 1 \
	--per_io_tasks -r 1 --foreground --defer_fetch_queue 1 \
	--refetch_on_signal < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
daemon_pid=$!

if ! _wait_queue_ready "${dev_id}" 0; then
	_fail_and_cleanup "queue 0 never became ready"
fi

kill -USR1 "$daemon_pid"
if ! _ublk_wait_kmsg "kublk: dev ${dev_id} stopped reaping" "$WAIT_SECS"; then
	_fail_and_cleanup "kublk did not stop reaping"
fi
if ! grep -q "^queue 1: .* canceling 1 " "${DEBUGFS_ROOT}/${dev_id}/dev_state"; then
	_fail_and_cleanup "queue 1 is ready before SIGUSR2"
fi

cpu=$(cut -d, -f1 < /sys/block/ublkb"${dev_id}"/mq/0/cpu_list)
# no fd of ours: a dd stuck in D state must not hold the caller's pipe open
read_one_block "${dev_id}" "$cpu" < /dev/null > /dev/null 2>&1 &
dd_pid=$!
if ! _ublk_wait_read_inflight "${dev_id}" "$WAIT_SECS"; then
	_fail_and_cleanup "the read never reached the driver"
fi

_ublk_stop_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
stop_pid=$!
if ! _wait_stop_dev_step "${dev_id}"; then
	_fail_and_cleanup "STOP_DEV never reached del_gendisk()"
fi

kill -USR2 "$daemon_pid"

# Unfixed, the FETCH_REQs of queue 1 sleep on ub->mutex for ever: kublk,
# STOP_DEV and dd stay in D state and nothing here can end them.
if ! _ublk_wait_pid_gone "$stop_pid" "$WAIT_SECS"; then
	echo "STOP_DEV did not return within ${WAIT_SECS}s"
	_show_result $TID 255
fi
if ! _ublk_wait_pid_gone "$dd_pid" "$WAIT_SECS"; then
	echo "the read did not end within ${WAIT_SECS}s"
	_show_result $TID 255
fi

# END_USER_RECOVERY fails on the stopped device, and kublk then sends DEL_DEV
if ! _ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"; then
	echo "kublk did not exit within ${WAIT_SECS}s"
	kill -9 "$daemon_pid"
	_show_result $TID 255
fi
if [ -e /dev/ublkc"${dev_id}" ]; then
	echo "kublk left dev ${dev_id} behind"
	ERR_CODE=255
else
	sed -i "/^${dev_id}$/d" "${UBLK_TEST_DIR}/.ublk_devs"
fi

if ! _check_dmesg; then
	echo "kernel complained during STOP_DEV"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
