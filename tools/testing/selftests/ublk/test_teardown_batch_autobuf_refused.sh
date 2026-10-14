#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Stop a batch device whose server commits a request with an auto registered
# buffer after STOP_DEV took the tag.
#
# ublk_abort_dev() clears UBLK_IO_FLAG_OWNED_BY_SRV of a tag the server holds,
# and the request keeps the reference of its auto registered buffer. The
# server's UBLK_U_IO_COMMIT_IO_CMDS on that tag is refused with -EBUSY. Unless
# the refusal unregisters the buffer nothing drops that reference while the
# server lives: del_gendisk() waits for ever.
#
# --hold_io_on_signal holds the read; SIGUSR2 makes the server commit it only
# once debugfs shows STOP_DEV took the tag. Judged by del_gendisk() returning.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
DEPTH=4
BUSY_RES=-16
DEV_ARGS="-t null -b -q 1 -d ${DEPTH} --auto_zc --hold_io_on_signal --no_auto_part_scan"

_prep_test "teardown" "batch commit a tag with an auto registered buffer after STOP_DEV took it"

if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi
if ! _have_feature "BATCH_IO" || ! _have_feature "AUTO_BUF_REG"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Echo the result of a refused commit the kernel logged in this run, empty if
# none yet.
# Usage: _commit_refused_res <dev_id> <tag>
_commit_refused_res()
{
	local from

	from=$(dmesg | grep -n "ublk selftest: ${TID} starting" | tail -1 |
		cut -d: -f1)
	if [ -z "$from" ]; then
		from=0
	fi
	dmesg | tail -n +$((from + 1)) |
		sed -n "s/.*ublk_batch_commit_io: dev $1 queue 0 io $2: commit failure //p" |
		tail -1
}

# Usage: _wait_commit_refused_res <dev_id> <tag>
_wait_commit_refused_res()
{
	local tenths=0
	local res

	while [ "$tenths" -lt $((WAIT_SECS * 10)) ]; do
		res=$(_commit_refused_res "$1" "$2")
		if [ -n "$res" ]; then
			echo "$res"
			return 0
		fi
		sleep 0.1
		tenths=$((tenths + 1))
	done
	return 1
}

dev_id=$(_add_ublk_dev $DEV_ARGS)
_check_add_dev "$TID" $?
server_pid=$(_get_ublk_daemon_pid "${dev_id}")

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

_ublk_stop_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
stop_pid=$!
if [ "$ERR_CODE" -eq 0 ] && ! _ublk_wait_tag_taken "${dev_id}" "$tag" "$WAIT_SECS"; then
	echo "setup: STOP_DEV did not take tag ${tag} within ${WAIT_SECS}s"
	ERR_CODE=255
fi

kill -USR2 "$server_pid"
if [ "$ERR_CODE" -eq 0 ]; then
	if ! res=$(_wait_commit_refused_res "${dev_id}" "$tag"); then
		echo "setup: no refused COMMIT_IO_CMDS on tag ${tag} within ${WAIT_SECS}s"
		ERR_CODE=255
	elif [ "$res" -ne "$BUSY_RES" ]; then
		echo "setup: COMMIT_IO_CMDS on tag ${tag} got ${res}, not ${BUSY_RES}"
		ERR_CODE=255
	fi
fi
if [ "$ERR_CODE" -eq 0 ] && ! _ublk_wait_disk_detached "${dev_id}" "$WAIT_SECS"; then
	echo "del_gendisk() of dev ${dev_id} wedged: the refused commit left the buffer registered"
	ps -eo pid,stat,wchan:32,args | grep -E "[k]ublk|[d]d if="
	_ublk_dump_dev_state "${dev_id}"
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
