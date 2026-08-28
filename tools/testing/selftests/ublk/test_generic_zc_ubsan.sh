#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Drive zero copy dispatch wide enough to fill imu->bvec[] past its first
# entry, under UBSAN bounds checking.
#
# io_buffer_register_bvec() fills a __counted_by array, so a wrong nr_bvecs is
# reported rather than returned. Both registering paths are covered: the
# driver's, from ublk_dispatch_req(), and the server's UBLK_IO_REGISTER_IO_BUF.
# The failure is a kernel log line rather than an exit code.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0

_prep_test "generic" "zero copy dispatch does not report out of bounds"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

_run_zc_io()
{
	local dev_id

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev $TID $?

	# imu->bvec[] is filled one entry per segment, so a request has to
	# span several pages for the fill loop to run past the first
	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=randrw --norandommap --direct=1 --bs=256k --iodepth=16 \
		--numjobs=2 --runtime=5 --time_based > /dev/null 2>&1

	_ublk_del_dev "${dev_id}"
	udevadm settle
}

_create_backfile 0 256M

if _have_feature "AUTO_BUF_REG"; then
	# the driver registers the buffer from ublk_dispatch_req()
	_run_zc_io -t loop -q 2 --auto_zc "${UBLK_BACKFILES[0]}"
fi

if _have_feature "ZERO_COPY"; then
	# the ublk server registers it with UBLK_IO_REGISTER_IO_BUF
	_run_zc_io -t loop -q 2 -z "${UBLK_BACKFILES[0]}"
fi

# without CONFIG_UBSAN_BOUNDS the bounds check against imu->nr_bvecs is not
# compiled in and this cannot fail, so the arms above are all there is
if ! _check_dmesg; then
	echo "kernel complained during zero copy IO"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
