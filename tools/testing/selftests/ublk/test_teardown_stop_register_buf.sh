#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Register a zero copy buffer on the server task while STOP_DEV drops the
# dispatch reference of the same tag.
#
# ublk_daemon_register_io_buf() counts an on-task buffer in
# task_registered_buffers, not in the request reference, and stores the
# count after io_buffer_register_request(). __ublk_fail_req() subtracts
# UBLK_REFCOUNT_INIT - task_registered_buffers off the server task. When
# STOP_DEV runs between the two, it reads 0, ends the request, and the
# buffer in the server's io_uring table still points at its pages.
#
# --hold_io_on_signal holds the read; SIGUSR2 hands it to the null target,
# whose UBLK_IO_REGISTER_IO_BUF stops in delay_register_io_buf right after
# the buffer went into the table; STOP_DEV runs inside that delay. Judged by
# the tag: the request ended (fail) or still started on the reference of
# the buffer (pass).

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
WAIT_SECS=$((20 * UBLK_WAIT_SCALE))
# not scaled: with the fix the request waits for this delay, and
# ublk_warn_started_rqs() reports a request still started after 5 s
REG_DELAY_US=4000000
DEPTH=4
DEV_ARGS="-t null -q 1 -d ${DEPTH} -z --hold_io_on_signal --no_auto_part_scan"

_prep_test "teardown" "zero copy buffer registered inside the STOP_DEV reference drop"

if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi
if ! _have_feature "ZERO_COPY"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Echo the tag of the held read: started and owned by the server.
# Usage: _wait_held_tag <dev_id>
_wait_held_tag()
{
	local tenths=0
	local flags
	local tag

	while [ "$tenths" -lt $((WAIT_SECS * 10)) ]; do
		for ((tag = 0; tag < DEPTH; tag++)); do
			flags=$(_ublk_started_tag_flags "$1" "$tag")
			if [[ "$flags" == *OWNED_BY_SRV* ]]; then
				echo "$tag"
				return 0
			fi
		done
		sleep 0.1
		tenths=$((tenths + 1))
	done
	return 1
}

# Echo "ended" once the request of the tag is no longer started, or
# "ref1" once STOP_DEV left it started on one reference. A reference above
# 1 is STOP_DEV between taking the tag and subtracting.
# Usage: _wait_tag_disposed <dev_id> <tag>
_wait_tag_disposed()
{
	local tenths=0
	local ref

	while [ "$tenths" -lt $((WAIT_SECS * 10)) ]; do
		ref=$(_ublk_started_tag_value "$1" "$2" ref)
		if [ -z "$ref" ]; then
			echo "ended"
			return 0
		fi
		if [ "$ref" -eq 1 ]; then
			echo "ref1"
			return 0
		fi
		sleep 0.1
		tenths=$((tenths + 1))
	done
	return 1
}

# Not judged. The server unregisters the buffer after the delay, so
# STOP_DEV returns in both outcomes.
_teardown()
{
	if ! _ublk_wait_pid_gone "$stop_pid" "$WAIT_SECS"; then
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
if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/delay_register_io_buf" ]; then
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
if [ "$ERR_CODE" -eq 0 ] && ! tag=$(_wait_held_tag "${dev_id}"); then
	echo "setup: no read held by the server within ${WAIT_SECS}s"
	ERR_CODE=255
fi

# armed only now: the held read is the only one, so only its register
# takes it
_ublk_arm_delay_point "${dev_id}" delay_register_io_buf "$REG_DELAY_US"
# the delay starts after this point, so the elapsed time from here bounds it
start_ns=$(date +%s%N)
kill -USR2 "$server_pid"
if [ "$ERR_CODE" -eq 0 ] &&
		! _ublk_wait_delay_point_fired "${dev_id}" delay_register_io_buf "$WAIT_SECS"; then
	echo "setup: UBLK_IO_REGISTER_IO_BUF on tag ${tag} did not reach the delay point"
	ERR_CODE=255
fi

_ublk_stop_dev "${dev_id}" < /dev/null > /dev/null 2>&1 &
stop_pid=$!
if [ "$ERR_CODE" -eq 0 ]; then
	if ! disposed=$(_wait_tag_disposed "${dev_id}" "$tag"); then
		echo "setup: STOP_DEV did not take tag ${tag} within ${WAIT_SECS}s"
		ERR_CODE=255
	else
		elapsed_us=$((($(date +%s%N) - start_ns) / 1000))
		if [ "$elapsed_us" -ge "$REG_DELAY_US" ]; then
			echo "setup: tag ${tag} read ${elapsed_us} us after the register, past the delay"
			_teardown
			_cleanup_test
			exit "$UBLK_SKIP_CODE"
		fi
		if [ "$disposed" = ended ]; then
			echo "STOP_DEV ended the request of tag ${tag} while the server's buffer for it was registered"
			ERR_CODE=255
		fi
	fi
fi
if [ "$ERR_CODE" -eq 0 ] && ! _ublk_wait_disk_detached "${dev_id}" "$WAIT_SECS"; then
	echo "del_gendisk() of dev ${dev_id} wedged after the buffer was unregistered"
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
