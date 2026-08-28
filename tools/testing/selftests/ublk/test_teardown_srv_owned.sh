#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Delete a device while requests are owned by the server.
#
# blk_mq_tagset_busy_iter() must end exactly the set del_gendisk() waits for,
# and a request the walk finds started but unowned stalls the freeze that
# follows. The other delete cases run null devices, which complete at once and
# rarely have a request with the server when the delete lands.
#
# The fault_inject target answers each IO with a timeout, so every fetched tag
# stays OWNED_BY_SRV for as long as the delay lasts and the delete meets a full
# queue of them.

. "$(cd "$(dirname "$0")" && pwd)"/test_common.sh

ERR_CODE=0
LOOPS=2
RUNTIME=15

_prep_test "teardown" "delete with requests owned by the server"

if ! _have_program fio; then
	_cleanup_test
	exit "$UBLK_SKIP_CODE"
fi

_create_backfile 0 1G

# A null device completes at once, so a request is rarely with the server
# when the delete arrives. Large writes to a backing file keep it there,
# which is the set del_gendisk() waits for and the set the tagset walk has
# to end.
for ((loop = 0; loop < LOOPS; loop++)); do
	# the fault_inject target answers each IO with a timeout, so every
	# fetched tag is OWNED_BY_SRV for the whole window and the delete
	# meets a full queue of them rather than whatever happens to be there
	_ublk_run_del_mid_io 4k randwrite 4 $RUNTIME \
		-t fault_inject -q 2 -d 64 --delay_us 5000000 || ERR_CODE=255

	_ublk_run_del_mid_io 1M write 4 $RUNTIME \
		-t loop -q 2 -d 64 "${UBLK_BACKFILES[0]}" || ERR_CODE=255

	if _have_feature "BATCH_IO"; then
		# the walk covers the whole tag set, so both queue kinds end
		# up in the same iteration rather than in per-queue arms
		_ublk_run_del_mid_io 1M write 4 $RUNTIME \
			-t loop -q 2 -d 64 -b "${UBLK_BACKFILES[0]}" ||
			ERR_CODE=255
	fi

	if _have_feature "AUTO_BUF_REG"; then
		_ublk_run_del_mid_io 1M write 4 $RUNTIME \
			-t loop -q 2 -d 64 --auto_zc "${UBLK_BACKFILES[0]}" ||
			ERR_CODE=255
	fi
done

# A request the walk finds started but unowned stalls the freeze that
# follows, so the delete never returns rather than reporting anything
if ! _check_dmesg; then
	echo "kernel complained during teardown"
	ERR_CODE=255
fi

_cleanup_test
_show_result $TID $ERR_CODE
