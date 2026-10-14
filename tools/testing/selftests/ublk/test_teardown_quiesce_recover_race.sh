#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Kill and recover the server while QUIESCE_DEV waits between dropping
# ub->mutex and its ublk_cancel_dev().
#
# delay_cancel_dev holds QUIESCE_DEV there, and a new server recovers the
# device inside the delay. Unless the old server's release work waits for that
# ublk_cancel_dev(), it aborts the new server's FETCH commands: kublk exits, or
# a batch queue gets force_abort and fails every request.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
# a kill and a full recovery take well under a second
CANCEL_DELAY_US=5000000
NR_TAGS=2

_prep_test "teardown" "kill and recover while QUIESCE_DEV cancels"

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

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

# UB_STATE_OPEN is cleared last in the killed server's release work, and
# START_USER_RECOVERY refuses the device until then.
# Usage: _wait_dev_closed <dev_id>
_wait_dev_closed()
{
	local tenths=0

	while [ "$tenths" -lt $((WAIT_SECS * 10)) ]; do
		if grep -q "^ub_state: .* open 0 " "${DEBUGFS_ROOT}/$1/dev_state"; then
			return 0
		fi
		sleep 0.1
		tenths=$((tenths + 1))
	done
	return 1
}

quiesce_dev()
{
	"${UBLK_PROG}" quiesce -n "$1"
}

# Usage: quiesce_kill_recover <add args...>
quiesce_kill_recover()
{
	local dev_id
	local daemon_pid
	local quiesce_pid
	local state
	local res=0

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?
	if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/delay_cancel_dev" ]; then
		echo "no delay points (CONFIG_FAULT_INJECTION_DEBUG_FS)"
		_cleanup_test
		exit "$UBLK_SKIP_CODE"
	fi
	daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

	_arm_delay_point "${dev_id}" delay_cancel_dev "$CANCEL_DELAY_US"
	quiesce_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
	# $! is the PID of the job just started with &
	quiesce_pid=$!
	if ! _ublk_wait_delay_point_fired "${dev_id}" delay_cancel_dev "$WAIT_SECS"; then
		echo "QUIESCE_DEV did not reach ublk_cancel_dev()"
		res=1
	fi

	if [ "$res" -eq 0 ]; then
		kill -9 "$daemon_pid"
		if ! _wait_dev_closed "${dev_id}"; then
			echo "release work of dev ${dev_id} did not finish"
			res=1
		fi
	fi

	if [ "$res" -eq 0 ]; then
		state=$(_recover_ublk_dev -n "${dev_id}" "$@")
		if [ "$state" != "LIVE" ]; then
			echo "dev ${dev_id} isn't recovered(${state})"
			res=1
		fi
		# not judged: expected only without the release work's wait
		if kill -0 "$quiesce_pid" 2>/dev/null; then
			echo "dev ${dev_id} recovered inside the QUIESCE_DEV cancel delay"
		fi
	fi

	if ! _ublk_wait_pid_gone "$quiesce_pid" "$WAIT_SECS"; then
		echo "QUIESCE_DEV did not return within ${WAIT_SECS}s"
		res=1
	fi
	if [ "$res" -eq 0 ] &&
			! _ublk_wait_server_cmds "${dev_id}" "$NR_TAGS" "$WAIT_SECS"; then
		echo "QUIESCE_DEV aborted the commands of the recovered server"
		_ublk_dump_dev_state "${dev_id}"
		res=1
	fi

	if ! _ublk_del_dev_timeout "${dev_id}"; then
		res=1
	fi
	return $res
}

if ! quiesce_kill_recover -t null -q 1 -d "$NR_TAGS" -r 1; then
	ERR_CODE=255
fi
if _have_feature "BATCH_IO"; then
	if ! quiesce_kill_recover -t null -q 1 -d "$NR_TAGS" -r 1 -b; then
		ERR_CODE=255
	fi
fi
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

if ! _check_dmesg; then
	echo "kernel complained during quiesce and recover"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
