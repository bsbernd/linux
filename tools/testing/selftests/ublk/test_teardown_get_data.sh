#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Land a delete against the read-modify-write of io->flags on a tag.
#
# UBLK_IO_FLAG_NEED_GET_DATA and UBLK_IO_FLAG_AUTO_BUF_REG are set and cleared
# while cancellation updates the same word, and a lost update drops
# UBLK_IO_FLAG_CANCELED, leaving the tag completed twice or never. The generic
# cases drive both features but tear the device down only once IO has stopped.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
LOOPS=2
RUNTIME=10

_prep_test "teardown" "delete against the flag updates on a tag"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

_create_backfile 0 256M

# UBLK_IO_FLAG_NEED_GET_DATA is set on dispatch and cleared when the server
# asks for the data, and UBLK_IO_FLAG_AUTO_BUF_REG is cleared when the
# buffer goes -- all read-modify-write on io->flags, concurrent with the
# cancellation the delete below starts
for ((loop = 0; loop < LOOPS; loop++)); do
	_ublk_run_del_mid_io 4k randrw 4 $RUNTIME \
		-t loop -q 4 -g "${UBLK_BACKFILES[0]}" || ERR_CODE=255

	# the two flags never share a device: add_dev drops NEED_GET_DATA as
	# soon as AUTO_BUF_REG is set, so each gets its own run
	if _have_feature "AUTO_BUF_REG"; then
		_ublk_run_del_mid_io 4k randrw 4 $RUNTIME \
			-t loop -q 4 --auto_zc "${UBLK_BACKFILES[0]}" ||
			ERR_CODE=255
	fi
done

# a lost update drops UBLK_IO_FLAG_CANCELED, and the tag is then completed
# twice or never: the first is a splat, the second a delete that hangs
if ! _check_dmesg; then
	echo "kernel complained during teardown"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
