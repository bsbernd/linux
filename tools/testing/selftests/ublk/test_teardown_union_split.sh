#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Check that a tag holds a command or a request, never both.
#
# Which of io->cmd and io->req is in use is told by io->flags, and reading the
# wrong one gives NULL rather than a pointer of the other type that still looks
# valid. ublk/<dev_id>/tags prints exactly that, so the invariant can be read
# straight off a running device.
#
# Sampling while fio runs walks the tags through every state they take, rather
# than catching them idle where only one field is ever set anyway.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
SAMPLES=40

_prep_test "teardown" "a tag holds a command or a request, never both"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

if ! DEBUGFS_ROOT=$(_ublk_debugfs_root); then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

# Which of the two a tag holds is told by its flags, and a tag holding
# neither must report neither. Sampling while IO runs walks tags through
# every state they take.
ublk_check_one_owner()
{
	local dev_id
	local fio_pid
	local tags
	local bad
	local i

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?
	tags="${DEBUGFS_ROOT}/${dev_id}/tags"

	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=randrw --norandommap --iodepth=64 --bs=4k --numjobs=4 \
		--runtime=10 --time_based > /dev/null 2>&1 &
	fio_pid=$!

	for ((i = 0; i < SAMPLES; i++)); do
		# %p renders an unset pointer as zeroes or as (null) depending
		# on the kernel, so compare the value rather than one spelling
		bad=$(awk '/^  tag /{
				cmd = ""; req = "";
				for (f = 1; f < NF; f++) {
					if ($f == "cmd") cmd = $(f + 1);
					if ($f == "req") req = $(f + 1);
				}
				if (cmd !~ /^(0+|\(null\))$/ &&
				    req !~ /^(0+|\(null\))$/)
					print;
			}' "${tags}" 2>/dev/null)
		if [ -n "$bad" ]; then
			echo "tag holds a command and a request at once:"
			echo "$bad" | sed 's/^/\t/'
			ERR_CODE=255
			break
		fi
		sleep 0.2
	done

	kill -INT $fio_pid > /dev/null 2>&1
	_ublk_wait_fio "$fio_pid" 60 || ERR_CODE=255
	_ublk_del_dev_timeout "${dev_id}" || ERR_CODE=255
}

_create_backfile 0 256M

ublk_check_one_owner -t null -q 4 -d 128
ublk_check_one_owner -t loop -q 2 -d 64 "${UBLK_BACKFILES[0]}"

if _have_feature "BATCH_IO"; then
	ublk_check_one_owner -t null -q 4 -d 128 -b
fi

if ! _check_dmesg; then
	echo "kernel complained while sampling tag state"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
