#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Kill a recovering server while another process waits in END_USER_RECOVERY.
#
# END_USER_RECOVERY waits until every queue has fetched, or until STOP_DEV
# set UB_STATE_STOPPING. A recovering server that dies before fetching all
# queues leaves the device without a server, and STOP_DEV sets that bit only
# while a server has /dev/ublkcN open, so the waiter returns only on a signal.
# kublk sends END_USER_RECOVERY from its own process, which the kill ends too,
# so here a separate "kublk end_recovery" sends it.
#
# The recovering server fetches queue 0 only and holds back queue 1. The run
# where the server then fetches queue 1 comes first and must end LIVE.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))
DEV_ARGS="-t null -q 2 -d 2 -r 1 --per_io_tasks --nthreads 1"

_prep_test "teardown" "kill a recovering server while END_USER_RECOVERY waits"

# Usage: end_recovery_kill fetch|kill|kill_stop
# $1: fetch lets the server fetch queue 1, kill kills it, kill_stop kills it
#     and stops the device
end_recovery_kill()
{
	local action=$1
	local server_pid=""
	local end_pid=""
	local dev_id
	local state
	local res=0

	# shellcheck disable=SC2086
	dev_id=$(_add_ublk_dev $DEV_ARGS)
	_check_add_dev "$TID" $?

	state=$(__ublk_kill_daemon "${dev_id}" "QUIESCED")
	if [ "$state" != "QUIESCED" ]; then
		echo "dev ${dev_id} isn't quiesced(${state}) after kill"
		res=1
	fi

	# shellcheck disable=SC2086
	if [ "$res" -eq 0 ] && ! "${UBLK_PROG}" recover -n "${dev_id}" $DEV_ARGS \
			--refetch_on_signal --defer_fetch_queue 1 \
			--no_end_recovery > /dev/null; then
		echo "recover of dev ${dev_id} failed"
		res=1
	fi
	if [ "$res" -eq 0 ]; then
		server_pid=$(_ublk_char_dev_holder "${dev_id}")
		if [ -z "$server_pid" ]; then
			echo "no recovering server holds /dev/ublkc${dev_id}"
			res=1
		fi
	fi

	if [ "$res" -eq 0 ]; then
		"${UBLK_PROG}" end_recovery -n "${dev_id}" \
			--daemon_pid "$server_pid" < /dev/null > /dev/null 2>&1 &
		# $! is the PID of the END_USER_RECOVERY sender
		end_pid=$!
		# queue 1 has not fetched, so the sender waits on any kernel
		if _ublk_wait_pid_gone "$end_pid" "$UBLK_STATE_SLEEP"; then
			echo "END_USER_RECOVERY on dev ${dev_id} returned before queue 1 fetched"
			end_pid=""
			res=1
		fi
	fi

	if [ "$res" -eq 0 ] && [ "$action" = fetch ]; then
		# SIGUSR1 parks the IO thread, SIGUSR2 makes it fetch queue 1
		kill -USR1 "$server_pid"
		if ! _ublk_wait_kmsg "kublk: dev ${dev_id} stopped reaping" \
				"$WAIT_SECS"; then
			echo "kublk did not stop reaping"
			res=1
		fi
		kill -USR2 "$server_pid"
	elif [ "$res" -eq 0 ]; then
		kill -9 "$server_pid"
		if ! _ublk_wait_pid_gone "$server_pid" "$WAIT_SECS"; then
			echo "recovering server of dev ${dev_id} did not exit after SIGKILL"
			res=1
		fi
	fi
	if [ "$res" -eq 0 ] && [ "$action" = kill_stop ] &&
			! timeout "$WAIT_SECS" "${UBLK_PROG}" stop -n "${dev_id}"; then
		echo "STOP_DEV of dev ${dev_id} failed"
		res=1
	fi

	if [ "$res" -eq 0 ] && ! _ublk_wait_pid_gone "$end_pid" "$WAIT_SECS"; then
		echo "END_USER_RECOVERY on dev ${dev_id} did not return ${WAIT_SECS}s after ${action} of the recovering server"
		res=1
	fi
	if [ "$res" -eq 0 ] && [ "$action" = fetch ]; then
		state=$(_get_ublk_dev_state "${dev_id}")
		if [ "$state" != "LIVE" ]; then
			echo "dev ${dev_id} isn't LIVE(${state}) after END_USER_RECOVERY"
			res=1
		fi
	fi

	# the wait in END_USER_RECOVERY is interruptible
	if [ -n "$end_pid" ]; then
		kill -9 "$end_pid" > /dev/null 2>&1
		wait "$end_pid" > /dev/null 2>&1
	fi
	if ! _ublk_del_dev_timeout "${dev_id}"; then
		res=1
	fi
	return $res
}

if ! end_recovery_kill fetch; then
	ERR_CODE=255
fi
if ! end_recovery_kill kill; then
	ERR_CODE=255
fi
if ! end_recovery_kill kill_stop; then
	ERR_CODE=255
fi
if [ "$ERR_CODE" -eq 0 ]; then
	echo "verdict: pass"
else
	echo "verdict: fail"
fi

if ! _check_dmesg; then
	echo "kernel complained during recovery"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
