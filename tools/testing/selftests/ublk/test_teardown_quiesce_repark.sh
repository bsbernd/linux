#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Quiesce repeatedly while the server keeps parking commands.
#
# QUIESCE_DEV leaves the server live, so it can park a command on a tag
# ublk_cancel_queue() has already visited, and that pass never comes back. A
# held request committed after the quiesce puts it there every run; fio then
# drives the queue throughout so each quiesce lands at a different point.
#
# The failure is one that never returns, so both the quiesce and the delete are
# bounded.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
CYCLES=4
RUNTIME=30

_prep_test "teardown" "quiesce with the server returning commands"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Hold one request in the server through the cancel pass of a quiesce, then
# commit it: the COMMIT_AND_FETCH_REQ lands on a tag the pass has visited, every
# run. The other tag gets UBLK_IO_RES_ABORT; the held one keeps the server up.
ublk_commit_after_quiesce()
{
	local deadline=$((10 * UBLK_WAIT_SCALE))
	local daemon_pid
	local dev_id
	local dd_pid
	local state
	local secs=0
	local res=0

	dev_id=$(_add_ublk_dev -t null -q 1 -d 2 -r 1 --hold_io_on_signal \
		--no_auto_part_scan)
	_check_add_dev "$TID" $?
	daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")

	# armed only now, so the reads udev issued at add were served
	kill -USR1 "$daemon_pid"
	dd if=/dev/ublkb"${dev_id}" of=/dev/null bs=4k count=1 iflag=direct \
		> /dev/null 2>&1 &
	dd_pid=$!

	if ! _ublk_wait_tag_flag_present "${dev_id}" OWNED_BY_SRV 10; then
		res=1
	# returns once ublk_cancel_dev() has walked every tag
	elif ! ${UBLK_PROG} quiesce -n "${dev_id}"; then
		echo "quiesce dev ${dev_id} failed"
		res=1
	fi

	# a SIGUSR2 landing just before the IO thread sleeps is not seen, so
	# repeat it until the server is gone
	while [ "$res" -eq 0 ] && [ "$secs" -lt "$deadline" ]; do
		kill -USR2 "$daemon_pid" > /dev/null 2>&1
		state=$(_get_ublk_dev_state "${dev_id}")
		if [ "$state" = "QUIESCED" ]; then
			break
		fi
		sleep 1
		secs=$((secs + 1))
	done
	if [ "$res" -eq 0 ] && [ "$state" != "QUIESCED" ]; then
		echo "dev ${dev_id} isn't quiesced(${state}) after the commit"
		_ublk_dump_dev_state "${dev_id}"
		res=1
	fi

	_ublk_del_dev_timeout "${dev_id}" || res=1
	wait "$dd_pid" > /dev/null 2>&1
	return $res
}

# the held tag is found through debugfs; without it nothing is held
if ! _ublk_debugfs_root > /dev/null; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

ublk_commit_after_quiesce || ERR_CODE=255

_create_backfile 0 256M

_ublk_run_quiesce_cycles "$CYCLES" "$RUNTIME" -t null -q 4 -d 128 -r 1 ||
	ERR_CODE=255
_ublk_run_quiesce_cycles "$CYCLES" "$RUNTIME" -t loop -q 2 -d 64 -r 1 \
	"${UBLK_BACKFILES[0]}" || ERR_CODE=255

if ! _check_dmesg; then
	echo "kernel complained during quiesce and recover"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
