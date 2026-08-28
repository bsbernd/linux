#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Walk the shmem buffer tree on a UBLK_F_SHMEM_ZC device under PROVE_RCU.
#
# ublk_init_iod() walks ub->buf_tree for every request, and the queue freeze
# that keeps writers away is invisible to the maple tree, so a walk holding
# neither the tree lock nor RCU draws a lockdep report. That report costs no
# exit code, so the verdict comes from the kernel log.
#
# No buffer is registered on purpose: an empty tree is walked the same way.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0

_prep_test "generic" "shmem buffer walk holds the tree lock"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! _have_feature "SHMEM_ZC"; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

_run_shmem_io()
{
	local dev_id

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev $TID $?

	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=randrw --norandommap --direct=1 --bs=4k --iodepth=32 \
		--numjobs=2 --runtime=5 --time_based > /dev/null 2>&1

	_ublk_del_dev "${dev_id}"
	udevadm settle
}

_create_backfile 0 256M

# no buffer is registered: ublk_init_iod() walks the tree for every request
# on a UBLK_F_SHMEM_ZC device, and an empty tree is walked the same way
_run_shmem_io -t null -q 2 --shmem_zc
_run_shmem_io -t loop -q 2 --shmem_zc "${UBLK_BACKFILES[0]}"

# without CONFIG_PROVE_RCU the maple tree does not check who holds it and
# this cannot fail
if ! _check_dmesg; then
	echo "kernel complained during shmem zero-copy IO"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
