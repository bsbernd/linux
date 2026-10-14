#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0

_prep_test "fault_inject" "fast cleanup when all I/Os of one hctx are in server"

_dd_write() {
	local dev_id=$1

	# a write to a missing node would create a regular file and succeed
	if [ ! -b /dev/ublkb${dev_id} ]; then
		echo "/dev/ublkb${dev_id} is not a block device"
		return 1
	fi
	dd if=/dev/urandom of=/dev/ublkb${dev_id} oflag=direct conv=nocreat bs=4k count=1 status=none > /dev/null 2>&1
}

# A delay that never happens lets dd finish before the kill and pass the
# test by luck, so the write must be seen held by the server first.
# Usage: _wait_write_in_server <dev_id> <dd_pid>
_wait_write_in_server() {
	local dev_id=$1
	local dd_pid=$2
	local tags=""
	local dir
	local dd_alive
	local step

	if dir=$(_ublk_debugfs_root); then
		tags="${dir}/${dev_id}/tags"
	fi

	for ((step = 0; step < 50 * UBLK_WAIT_SCALE; step++)); do
		# sampled before the check, so an exit in between is caught next round
		dd_alive=0
		if kill -0 "$dd_pid" 2>/dev/null; then
			dd_alive=1
		fi
		if [ -f "$tags" ]; then
			if grep -q "OWNED_BY_SRV" "$tags"; then
				return 0
			fi
		elif [ "$(awk '{ print $2 }' "/sys/block/ublkb${dev_id}/inflight")" -gt 0 ]; then
			return 0
		fi
		if [ "$dd_alive" -eq 0 ]; then
			echo "IO not delayed: dd exited before the server held the write"
			return 1
		fi
		sleep 0.1
	done

	echo "write not held by the server after $((5 * UBLK_WAIT_SCALE))s"
	return 1
}

# configure ublk server to sleep 10s before completing each I/O: the kill
# below has to land first, also on a slow debug kernel
dev_id=$(_add_ublk_dev -t fault_inject -q 2 -d 1 --delay_us 10000000)
_check_add_dev $TID $?
daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

STARTTIME=${SECONDS}

_dd_write "${dev_id}" &
dd_pid=$!

if ! _wait_write_in_server "${dev_id}" "${dd_pid}"; then
	ERR_CODE=255
fi

kill -9 "$daemon_pid"
__ublk_kill_daemon ${dev_id} "DEAD" >/dev/null

wait $dd_pid
dd_exitcode=$?

ENDTIME=${SECONDS}
ELAPSED=$(($ENDTIME - $STARTTIME))

# assert that dd sees an error and exits quickly after ublk server is
# killed. previously this relied on seeing an I/O timeout and so would
# take ~30s
if [ $dd_exitcode -eq 0 ]; then
        echo "dd unexpectedly exited successfully!"
        ERR_CODE=255
fi
if [ $ELAPSED -ge 5 ]; then
        echo "dd took $ELAPSED seconds to exit (>= 5s tolerance)!"
        ERR_CODE=255
fi

# a delay far longer than asked would hide behind the kill above
dev2_id=$(_add_ublk_dev -t fault_inject -q 2 -d 1 --delay_us 2000000)
_check_add_dev $TID $?

STARTTIME=${SECONDS}
DEADLINE=$((STARTTIME + 2 + 10 * UBLK_WAIT_SCALE))

_dd_write "${dev2_id}" &
dd_pid=$!

while kill -0 "$dd_pid" 2>/dev/null; do
	if [ "$SECONDS" -gt "$DEADLINE" ]; then
		echo "write still not done after $((DEADLINE - STARTTIME))s"
		ERR_CODE=255
		__ublk_kill_daemon ${dev2_id} "DEAD" >/dev/null
		break
	fi
	sleep 0.1
done
wait $dd_pid

ELAPSED=$((SECONDS - STARTTIME))
if [ $ELAPSED -lt 2 ]; then
	echo "write took ${ELAPSED}s, the 2s delay did not happen"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
