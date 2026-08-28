#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Check that no tag is left UBLK_IO_FLAG_DISPATCHING after a quiesce.
#
# ublk_cancel_cmd() skips a tag carrying that flag, trusting the dispatch in
# flight to end it, and QUIESCE_DEV makes only the one pass. Once the device is
# quiesced no dispatch is left running, so a tag still marked is one nothing
# owns.
#
# The flag is polled rather than sampled: holding it for a moment is what it is
# for, and only a tag that never leaves the state is a failure.
#
# Two delay points first put a write's tag in that state while the cancel pass
# runs, every run: a parked command the pass skips keeps the server up, and the
# device never gets QUIESCED. fio then drives the queue as a soak.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
# one quiesce per device reads back unambiguously; four gets four attempts
CYCLES=${CYCLES:-4}
RUNTIME=40
WAIT_SECS=$((10 * UBLK_WAIT_SCALE))
# the write has to reach ->queue_rq() within this, after the test sees
# delay_cancel_dev fire
WALK_DELAY_US=1000000
# longer than WALK_DELAY_US, so the cancel pass runs while the tag is marked
PREP_DELAY_US=2000000

_prep_test "teardown" "no tag is left dispatching after a quiesce"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _have_feature "QUIESCE"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Usage: ublk_run_quiesce_dispatch <iodepth> <jobs> <ramp> <add args...>
ublk_run_quiesce_dispatch()
{
	local iodepth=$1
	local jobs=$2
	local ramp=$3
	local dev_id
	local fio_pid
	local cycle
	local state

	shift 3
	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=randrw --norandommap --iodepth="${iodepth}" --bs=4k \
		--numjobs="${jobs}" --runtime=$RUNTIME --time_based \
		> /dev/null 2>&1 &
	fio_pid=$!

	for ((cycle = 0; cycle < CYCLES; cycle++)); do
		[ "$ramp" == "ramp" ] && sleep 0.$((RANDOM % 9 + 1))

		state=$(__ublk_quiesce_dev "${dev_id}" "QUIESCED")
		if [ "$state" != "QUIESCED" ]; then
			echo "dev ${dev_id} isn't quiesced(${state:-failed})"
			_ublk_dump_dev_state "${dev_id}"
			ERR_CODE=255
			break
		fi

		# ublk_cancel_cmd() skips a tag being dispatched, trusting the
		# dispatch to end it. Once the device is quiesced no dispatch
		# is left running, so a tag still marked is one nothing owns.
		if ! _ublk_wait_tag_flag_gone "${dev_id}" DISPATCHING 30; then
			ERR_CODE=255
			break
		fi

		state=$(_recover_ublk_dev -n "${dev_id}" "$@")
		if [ "$state" != "LIVE" ]; then
			echo "dev ${dev_id} isn't recovered($state)"
			ERR_CODE=255
			break
		fi
	done

	# SIGINT makes fio stop submitting and wait out what is in flight, so
	# a request the dispatch neither published nor gave back keeps it
	# running -- which SIGKILL would hide
	kill -INT $fio_pid > /dev/null 2>&1
	_ublk_wait_fio "$fio_pid" 60 || ERR_CODE=255

	_ublk_del_dev_timeout "${dev_id}" || ERR_CODE=255
}

# A write reaches ->queue_rq() after QUIESCE_DEV set ->canceling and before
# its cancel pass: delay_cancel_dev holds ublk_cancel_dev(), delay_prep_cancel
# holds the write right after ublk_prep_req(). The other tag gets
# UBLK_IO_RES_ABORT; a skipped tag keeps the server up.
ublk_quiesce_marked_tag()
{
	local quiesce_pid
	local dev_id
	local dd_pid=
	local res=0

	# depth 2: the write leaves a tag idle, so ublk_wait_for_idle_io() returns
	dev_id=$(_add_ublk_dev -t null -q 1 -d 2 -r 1 --no_auto_part_scan)
	_check_add_dev "$TID" $?

	if [ ! -d "${DEBUGFS_ROOT}/${dev_id}/delay_prep_cancel" ]; then
		echo "no delay points (CONFIG_FAULT_INJECTION_DEBUG_FS)"
		_cleanup_test
		exit "$UBLK_SKIP_CODE"
	fi

	if ! _ublk_wait_no_inflight "${dev_id}" "$WAIT_SECS"; then
		echo "IO from the add still in flight"
		res=1
	else
		_ublk_arm_delay_point "${dev_id}" delay_cancel_dev "$WALK_DELAY_US"
		"${UBLK_PROG}" quiesce -n "${dev_id}" > /dev/null 2>&1 &
		# $! is the PID of the job just started with &
		quiesce_pid=$!
		if ! _ublk_wait_delay_point_fired "${dev_id}" delay_cancel_dev "$WAIT_SECS"; then
			echo "QUIESCE_DEV never reached ublk_cancel_dev()"
			res=1
		else
			# armed only now, so only the write takes it
			_ublk_arm_delay_point "${dev_id}" delay_prep_cancel \
				"$PREP_DELAY_US"
			_ublk_write_one_block "${dev_id}" < /dev/null > /dev/null 2>&1 &
			dd_pid=$!
			if ! _ublk_wait_delay_point_fired "${dev_id}" \
					delay_prep_cancel "$WAIT_SECS"; then
				echo "the write never reached ->queue_rq()"
				res=1
			fi
		fi
		if ! wait "$quiesce_pid"; then
			echo "quiesce dev ${dev_id} failed"
			res=1
		fi
	fi

	# the server exits once each tag got UBLK_IO_RES_ABORT, and only its
	# exit makes the device QUIESCED
	if [ "$res" -eq 0 ] && ! _ublk_wait_dev_state "${dev_id}" "QUIESCED" "$WAIT_SECS"; then
		echo "dev ${dev_id} not QUIESCED ${WAIT_SECS}s after QUIESCE_DEV"
		_ublk_dump_dev_state "${dev_id}"
		res=1
	fi
	# printed before the teardown below, which may not end
	if [ "$res" -eq 0 ]; then
		echo "verdict: pass"
	else
		echo "verdict: fail"
	fi

	# the server's ring exit cancels the skipped command
	if [ "$res" -ne 0 ]; then
		__ublk_kill_daemon "${dev_id}" "QUIESCED" > /dev/null
	fi
	# the write is requeued until the delete fails it
	_ublk_del_dev_timeout "${dev_id}" || res=1
	if [ -n "$dd_pid" ]; then
		wait "$dd_pid" > /dev/null 2>&1
	fi
	return $res
}

# the delay points live in the device's debugfs directory
if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

ublk_quiesce_marked_tag || ERR_CODE=255

_create_backfile 0 256M

ublk_run_quiesce_dispatch 64 4 ramp -t null -q 4 -d 128 -r 1
ublk_run_quiesce_dispatch 64 4 ramp -t loop -q 2 -d 64 -r 1 \
	"${UBLK_BACKFILES[0]}"

# One queue of depth one, quiesced with no ramp-up: the request in flight is
# the one between being started and being published, so the handover races
# the cancel pass rather than following it. A request the dispatch neither
# publishes nor gives back leaves fio waiting for ever.
ublk_run_quiesce_dispatch 1 1 no-ramp -t null -q 1 -d 1 -r 1
ublk_run_quiesce_dispatch 1 1 no-ramp -t loop -q 1 -d 1 -r 1 \
	"${UBLK_BACKFILES[0]}"

if ! _check_dmesg; then
	echo "kernel complained during quiesce and recover"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
