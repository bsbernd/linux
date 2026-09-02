#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# A recovery server that dies before it has fetched every I/O command must not
# deadlock its own exit.
#
# END_USER_RECOVERY waits for every queue to have fetched all its commands, and
# only the server can fetch, so a server that dies mid-fetch asks for something
# nobody can deliver. The command may sleep, so io_uring always runs it from an
# io-wq worker of that same thread group: if the wait does not give up, do_exit()
# waits for the worker and the worker waits for the server that is exiting. The
# task ends up unkillable in D state, which is why this test asserts that the
# recover command exits at all rather than checking a result code alone.
#
# Scenario: kill the daemon to reach QUIESCED, then recover with a server that
# dies partway through fetching.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
LOOPS=3

# hold the kill back so END_USER_RECOVERY is already waiting when the server dies
DIE_DELAY_US=300000

_prep_test "teardown" "END_USER_RECOVERY with a server that dies mid-fetch"

ublk_run_end_recovery()
{
	local dev_id
	local state

	dev_id=$(_add_ublk_dev -t fault_inject -r 1 -q 2)
	_check_add_dev "$TID" $?

	state=$(__ublk_kill_daemon "${dev_id}" "QUIESCED")
	if [ "$state" != "QUIESCED" ]; then
		echo "device isn't quiesced($state) before recovery"
		ERR_CODE=255
		return
	fi

	# 137 is the result when dying of SIGKILL. A hang here is the bug: the
	# dying task waits in do_exit() for the io-wq worker running
	# END_USER_RECOVERY, and that worker waits for a readiness only the
	# dying task could deliver.
	timeout 60 "${UBLK_PROG}" recover -n "${dev_id}" --foreground \
		-t fault_inject --die_during_fetch 1 \
		--die_during_fetch_delay_us "$DIE_DELAY_US" > /dev/null 2>&1
	RECOVER_RES=$?
	if [ "$RECOVER_RES" = 124 ]; then
		echo "recover did not exit: END_USER_RECOVERY never returned"
		ERR_CODE=255
		return
	fi
	if [ "$RECOVER_RES" != 137 ]; then
		echo "recover command exited with unexpected code ${RECOVER_RES}!"
		ERR_CODE=255
	fi

	_ublk_del_dev_timeout "${dev_id}" || ERR_CODE=255
}

for ((loop = 0; loop < LOOPS; loop++)); do
	ublk_run_end_recovery
	[ "$ERR_CODE" != 0 ] && break
done

if ! _check_dmesg; then
	echo "kernel complained during end recovery teardown"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
