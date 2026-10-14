#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# A ready queue must not keep a canceled tag counted while the device is not
# ready yet.
#
# Two queues of depth 1, two server threads with --per_io_tasks: thread 0
# serves queue 0, thread 1 queue 1. The first server is killed, so the
# recovery starts with ub->canceling set. In the recovering server thread 0
# fetches queue 0 tag 0, which makes queue 0 ready, and closes its ring,
# which cancels that command. On SIGUSR2 thread 1 fetches queue 1 tag 0.
# Queue 0 tag 0 holds no command, so queue 0 must be back at nr_io_ready 0
# with canceling set, and END_USER_RECOVERY must not make the device LIVE.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
READY_SECS=$((5 * UBLK_WAIT_SCALE))

_prep_test "teardown" "ready queue uncounts a canceled tag before the device is ready"

if ! _have_feature "PER_IO_DAEMON"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# tag states, canceling flags and nr_io_ready come only from debugfs
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Usage: _tag_lines <dev_id> <q_id> <tag>
_tag_lines()
{
	awk -v q_id="$2" -v tag="$3" '
		$1 == "queue" { in_queue = ($2 == q_id); in_tag = 0; next }
		$1 == "tag"   { in_tag = (in_queue && $2 == tag) }
		in_tag' "${DEBUGFS_ROOT}/$1/tags"
}

# Usage: _tag_shows <dev_id> <q_id> <tag> <word>
_tag_shows()
{
	if [ ! -f "${DEBUGFS_ROOT}/$1/tags" ]; then
		return 1
	fi
	_tag_lines "$1" "$2" "$3" | grep -q "$4"
}

# Usage: _cancel_done <dev_id>, the commands ublk_cancel_cmd() completed
_cancel_done()
{
	awk '$1 == "cancel_done:" { print $2 }' "${DEBUGFS_ROOT}/$1/teardown"
}

# Usage: _queue_field <dev_id> <q_id> <field>
_queue_field()
{
	awk -v q_id="$2:" -v name="$3" '$1 == "queue" && $2 == q_id {
		for (field = 3; field < NF; field++)
			if ($field == name)
				print $(field + 1)
	}' "${DEBUGFS_ROOT}/$1/dev_state"
}

# Return 0 once the cancel of queue 0 tag 0 counted after <baseline> ended.
# Usage: _wait_tag0_canceled <dev_id> <baseline>
_wait_tag0_canceled()
{
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if [ "$(_cancel_done "$1")" -gt "$2" ] &&
		   _tag_shows "$1" 0 0 CANCELED; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

# Usage: _wait_q1_fetched <dev_id>
_wait_q1_fetched()
{
	local secs=0

	while [ "$secs" -lt "$WAIT_SECS" ]; do
		if _tag_shows "$1" 1 0 CMD_PARKED; then
			return 0
		fi
		sleep 1
		secs=$((secs + 1))
	done
	return 1
}

# exec: the PID of the background job is then kublk itself
recover_server()
{
	exec "${UBLK_PROG}" recover -n "$1" -t null -q 2 -d 1 --nthreads 2 \
		--per_io_tasks -r 1 --exit_after_fetch --foreground
}

# END_USER_RECOVERY of a device that never gets ready waits until SIGKILL.
# Usage: _end_test <message> <exit code>
_end_test()
{
	echo "$1"
	if [ -n "$daemon_pid" ]; then
		kill -9 "$daemon_pid"
		if ! _ublk_wait_pid_gone "$daemon_pid" "$WAIT_SECS"; then
			echo "kublk did not exit within ${WAIT_SECS}s"
			ERR_CODE=255
		fi
	fi
	if ! _ublk_del_dev_timeout "$dev_id"; then
		ERR_CODE=255
	fi
	if ! _check_dmesg; then
		echo "kernel complained"
		ERR_CODE=255
	fi
	if [ "$2" -ne 0 ]; then
		ERR_CODE=$2
	fi
	if [ "$ERR_CODE" -eq 0 ]; then
		echo "verdict: pass"
	else
		echo "verdict: fail"
	fi
	_cleanup_test
	_show_result $TID $ERR_CODE
}

daemon_pid=""
dev_id=$(_add_ublk_dev -t null -q 2 -d 1 --nthreads 2 --per_io_tasks -r 1)
_check_add_dev "$TID" $?

state=$(__ublk_kill_daemon "${dev_id}" "QUIESCED")
if [ "$state" != "QUIESCED" ]; then
	_end_test "device isn't quiesced(${state}) after killing the server" 255
fi

baseline=$(_cancel_done "${dev_id}")
# no fd of ours: a server stuck in exit must not hold the caller's pipe open
recover_server "${dev_id}" < /dev/null > /dev/null 2>&1 &
# $! is the PID of the job just started with &
daemon_pid=$!

if ! _wait_tag0_canceled "${dev_id}" "$baseline"; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "closing thread 0's ring did not cancel queue 0 tag 0" 255
fi
# the path under test: ublk_start_cancel() skipped on ub->canceling
if ! grep -q "^canceling: 1$" "${DEBUGFS_ROOT}/${dev_id}/dev_state"; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "ub->canceling not left set by the killed server" 255
fi

kill -USR2 "$daemon_pid"
if ! _wait_q1_fetched "${dev_id}"; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "thread 1 did not fetch queue 1 tag 0" 255
fi

# no read: one on queue 0 tag 0 never completes and wedges the delete
if _ublk_wait_live "${dev_id}" "$READY_SECS"; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "dev ${dev_id} LIVE with queue 0 tag 0 canceled" 255
fi

nr_io_ready=$(_queue_field "${dev_id}" 0 nr_io_ready)
canceling=$(_queue_field "${dev_id}" 0 canceling)
if [ "$nr_io_ready" != 0 ] || [ "$canceling" != 1 ]; then
	_ublk_dump_dev_state "${dev_id}"
	_end_test "queue 0 nr_io_ready ${nr_io_ready} canceling ${canceling}, expected 0 and 1" 255
fi

_end_test "queue 0 nr_io_ready 0 canceling 1, dev ${dev_id} not LIVE" 0
