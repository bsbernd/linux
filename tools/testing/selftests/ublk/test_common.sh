#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

# Derive TID from script name: test_<type>_<num>.sh -> <type>_<num>
# Can be overridden in test script after sourcing this file
TID=$(basename "$0" .sh)
TID=${TID#test_}

UBLK_SKIP_CODE=4

_have_program() {
	if command -v "$1" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# Sleep with awareness of parallel execution.
# Usage: _ublk_sleep <normal_secs> <parallel_secs>
_ublk_sleep() {
	if [ "${JOBS:-1}" -gt 1 ]; then
		sleep "$2"
	else
		sleep "$1"
	fi
}

_get_disk_dev_t() {
	local dev_id=$1
	local dev
	local major
	local minor

	dev=/dev/ublkb"${dev_id}"
	major="0x"$(stat -c '%t' "$dev")
	minor="0x"$(stat -c '%T' "$dev")

	echo $(( (major & 0xfff) << 20 | (minor & 0xfffff) ))
}

_get_disk_size()
{
	lsblk -b -o SIZE -n "$1"
}

_run_fio_verify_io() {
	fio --name=verify --rw=randwrite --direct=1 --ioengine=libaio \
		--bs=8k --iodepth=32 --verify=crc32c --do_verify=1 \
		--verify_state_save=0 "$@" > /dev/null
}

_create_backfile() {
	local index=$1
	local new_size=$2
	local old_file
	local new_file

	old_file="${UBLK_BACKFILES[$index]}"
	[ -f "$old_file" ] && rm -f "$old_file"

	new_file=$(mktemp ${UBLK_TEST_DIR}/ublk_file_"${new_size}"_XXXXX)
	truncate -s "${new_size}" "${new_file}"
	UBLK_BACKFILES["$index"]="$new_file"
}

_remove_files() {
	local file

	for file in "${UBLK_BACKFILES[@]}"; do
		[ -f "$file" ] && rm -f "$file"
	done
	[ -f "$UBLK_TMP" ] && rm -f "$UBLK_TMP"
}

_create_tmp_dir() {
	local my_file;

	my_file=$(mktemp -d ${UBLK_TEST_DIR}/ublk_dir_XXXXX)
	echo "$my_file"
}

_remove_tmp_dir() {
	local dir=$1

	[ -d "$dir" ] && rmdir "$dir"
}

_mkfs_mount_test()
{
	local dev=$1
	shift
	local err_code=0
	local mnt_dir;

	mnt_dir=$(_create_tmp_dir)
	mkfs.ext4 -F "$dev" > /dev/null 2>&1
	err_code=$?
	if [ $err_code -ne 0 ]; then
		return $err_code
	fi

	mount -t ext4 "$dev" "$mnt_dir" > /dev/null 2>&1
	if [ $# -gt 0 ]; then
		cd "$mnt_dir" && "$@"
		err_code=$?
		cd - > /dev/null
	fi
	umount "$dev"
	if [ $err_code -eq 0 ]; then
		err_code=$?
	fi
	_remove_tmp_dir "$mnt_dir"
	return $err_code
}

_check_root() {
	local ksft_skip=4

	if [ $UID != 0 ]; then
		echo please run this as root >&2
		exit $ksft_skip
	fi
}

_get_ublk_dev_state() {
	${UBLK_PROG} list -n "$1" | grep "state" | awk '{print $11}'
}

_get_ublk_daemon_pid() {
	${UBLK_PROG} list -n "$1" | grep "pid" | awk '{print $7}'
}

# Echo the driver's debugfs root, or fail when the kernel was built without
# CONFIG_DEBUG_FS or debugfs is not mounted.
_ublk_debugfs_root() {
	local mnt

	mnt=$(awk '$3 == "debugfs" { print $2; exit }' /proc/mounts)
	[ -z "$mnt" ] && return 1
	[ -d "${mnt}/ublk" ] || return 1
	echo "${mnt}/ublk"
}

# A race that completes leaves nothing behind but a kernel log line, so a
# splat fails the test the way a bad exit code does. Only lines logged after
# _prep_test wrote its marker count.
UBLK_DMESG_BAD='BUG:|WARNING:|blocked for more than|circular locking'
UBLK_DMESG_BAD+='|refcount_t:|KCSAN:|array-index-out-of-bounds'
UBLK_DMESG_BAD+='|suspicious rcu_dereference'
# names the tag teardown failed to dispose of; a pr_warn, so no WARNING:
UBLK_DMESG_BAD+='|ublk_warn_started_rq'

_check_dmesg() {
	local from
	local out

	from=$(dmesg | grep -n "ublk selftest: ${TID} starting" | tail -1 |
		cut -d: -f1)
	[ -z "$from" ] && from=0
	out=$(dmesg | tail -n +$((from + 1)) | grep -E "$UBLK_DMESG_BAD")
	[ -z "$out" ] && return 0
	echo "$out" | sed 's/^/\t/'
	return 1
}

# A debug kernel (KCSAN, KASAN, lockdep) makes every wait longer, and a
# deadline that expires from slowness reports the same thing as a lost
# request. Scale every wait from one place rather than per call site.
UBLK_WAIT_SCALE=${UBLK_WAIT_SCALE:-1}

# A teardown that loses a request never returns, and an unbounded delete
# wedges the whole run instead of the case that hit it. It also holds
# ublk_ctl_mutex, so every later add and delete wedges behind it.
UBLK_DEL_TIMEOUT=$((30 * UBLK_WAIT_SCALE))

_ublk_del_dev_timeout() {
	local dev_id=$1
	local res

	timeout "$UBLK_DEL_TIMEOUT" "${UBLK_PROG}" del -n "${dev_id}" \
		> /dev/null 2>&1
	res=$?
	if [ "$res" -eq 124 ]; then
		echo "delete dev ${dev_id} wedged after ${UBLK_DEL_TIMEOUT}s"
		return 1
	fi
	if [ "$res" -ne 0 ]; then
		echo "delete dev ${dev_id} failed(${res})"
		return 1
	fi

	if [ -f "${UBLK_TEST_DIR}/.ublk_devs" ]; then
		sed -i "/^${dev_id}$/d" "${UBLK_TEST_DIR}/.ublk_devs"
	fi
	udevadm settle --timeout=20
	return 0
}

# IO that never completes is a request teardown neither ended nor requeued
_ublk_wait_fio() {
	local fio_pid=$1
	local deadline=$(($2 * UBLK_WAIT_SCALE))
	local secs=0

	while [ "$secs" -lt "$deadline" ] && kill -0 "$fio_pid" 2>/dev/null; do
		sleep 1
		secs=$((secs + 1))
	done

	if kill -0 "$fio_pid" 2>/dev/null; then
		echo "fio still has IO in flight after ${deadline}s"
		kill -9 "$fio_pid" > /dev/null 2>&1
		wait "$fio_pid" > /dev/null 2>&1
		return 1
	fi
	wait "$fio_pid" > /dev/null 2>&1
	return 0
}

# One teardown iteration: drive IO on a device built from the add arguments
# and land a delete in the middle of it. A delete issued once IO has
# quiesced cannot reach the window where the server may still be dispatching
# a tag, so the landing point is varied per iteration.
# Usage: _ublk_run_del_mid_io <bs> <rw> <jobs> <runtime> <add args...>
_ublk_run_del_mid_io() {
	local bs=$1
	local rw=$2
	local jobs=$3
	local runtime=$4
	local dev_id
	local fio_pid
	local res=0

	shift 4
	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw="${rw}" --norandommap --iodepth=256 --bs="${bs}" \
		--numjobs="${jobs}" --runtime="${runtime}" --time_based \
		> /dev/null 2>&1 &
	fio_pid=$!

	sleep 0.$((RANDOM % 9 + 1))

	_ublk_del_dev_timeout "${dev_id}" || res=1
	_ublk_wait_fio "$fio_pid" $((runtime + 60)) || res=1
	return $res
}

_prep_test() {
	_check_root
	local type=$1
	shift 1
	modprobe ublk_drv > /dev/null 2>&1
	local base_dir=${TMPDIR:-./ublktest-dir}
	mkdir -p "$base_dir"
	UBLK_TEST_DIR=$(mktemp -d ${base_dir}/${TID}.XXXXXX)
	UBLK_TEST_DIR=$(realpath ${UBLK_TEST_DIR})
	UBLK_TMP=$(mktemp ${UBLK_TEST_DIR}/ublk_test_XXXXX)
	[ "$UBLK_TEST_QUIET" -eq 0 ] && echo "ublk $type: $*"
	echo "ublk selftest: $TID starting at $(date '+%F %T')" | tee /dev/kmsg
}

_remove_test_files()
{
	local files=$*

	for file in ${files}; do
		[ -f "${file}" ] && rm -f "${file}"
	done
}

_show_result()
{
	if [ "$UBLK_TEST_SHOW_RESULT" -ne 0 ]; then
		if [ "$2" -eq 0 ]; then
			echo "$1 : [PASS]"
		elif [ "$2" -eq 4 ]; then
			echo "$1 : [SKIP]"
		else
			echo "$1 : [FAIL]"
		fi
	fi
	if [ "$2" -ne 0 ]; then
		_remove_files
		exit "$2"
	fi
	return 0
}

# don't call from sub-shell, otherwise can't exit
_check_add_dev()
{
	local tid=$1
	local code=$2

	if [ "${code}" -ne 0 ]; then
		_show_result "${tid}" "${code}"
	fi
}

_cleanup_test() {
	if [ -f "${UBLK_TEST_DIR}/.ublk_devs" ]; then
		while read -r dev_id; do
			${UBLK_PROG} del -n "${dev_id}"
		done < "${UBLK_TEST_DIR}/.ublk_devs"
		rm -f "${UBLK_TEST_DIR}/.ublk_devs"
	fi

	_remove_files
	rmdir ${UBLK_TEST_DIR}
	echo "ublk selftest: $TID done at $(date '+%F %T')" | tee /dev/kmsg
}

_have_feature()
{
	if  $UBLK_PROG "features" | grep "$1" > /dev/null 2>&1; then
		return 0
	fi
	return 1
}

_create_ublk_dev() {
	local dev_id;
	local cmd=$1
	local settle=$2

	shift 2

	if [ ! -c /dev/ublk-control ]; then
		return ${UBLK_SKIP_CODE}
	fi
	if echo "$@" | grep -q "\-z"; then
		if ! _have_feature "ZERO_COPY"; then
			return ${UBLK_SKIP_CODE}
		fi
	fi

	if ! dev_id=$("${UBLK_PROG}" "$cmd" "$@" | grep "dev id" | awk -F '[ :]' '{print $3}'); then
		echo "fail to add ublk dev $*"
		return 255
	fi

	if [ "$settle" = "yes" ]; then
		udevadm settle --timeout=20
	fi

	if [[ "$dev_id" =~ ^[0-9]+$ ]]; then
		echo "$dev_id" >> "${UBLK_TEST_DIR}/.ublk_devs"
		echo "${dev_id}"
	else
		return 255
	fi
}

_add_ublk_dev() {
	_create_ublk_dev "add" "yes" "$@"
}

_add_ublk_dev_no_settle() {
	_create_ublk_dev "add" "no" "$@"
}

_recover_ublk_dev() {
	local dev_id
	local state

	dev_id=$(_create_ublk_dev "recover" "yes" "$@")
	for ((j=0;j<100;j++)); do
		state=$(_get_ublk_dev_state "${dev_id}")
		[ "$state" == "LIVE" ] && break
		sleep 1
	done
	echo "$state"
}

# quiesce device and return ublk device state
__ublk_quiesce_dev()
{
	local dev_id=$1
	local exp_state=$2
	local state

	if ! ${UBLK_PROG} quiesce -n "${dev_id}"; then
		state=$(_get_ublk_dev_state "${dev_id}")
		return "$state"
	fi

	for ((j=0;j<100*UBLK_WAIT_SCALE;j++)); do
		state=$(_get_ublk_dev_state "${dev_id}")
		[ "$state" == "$exp_state" ] && break
		sleep 1
	done
	echo "$state"
}

# kill the ublk daemon and return ublk device state
__ublk_kill_daemon()
{
	local dev_id=$1
	local exp_state=$2
	local daemon_pid
	local state

	daemon_pid=$(_get_ublk_daemon_pid "${dev_id}")
	state=$(_get_ublk_dev_state "${dev_id}")

	for ((j=0;j<100*UBLK_WAIT_SCALE;j++)); do
		[ "$state" == "$exp_state" ] && break
		kill -9 "$daemon_pid" > /dev/null 2>&1
		sleep 1
		state=$(_get_ublk_dev_state "${dev_id}")
	done
	echo "$state"
}

_ublk_del_dev() {
	local dev_id=$1

	${UBLK_PROG} del -n "${dev_id}"

	# Remove from tracking file
	if [ -f "${UBLK_TEST_DIR}/.ublk_devs" ]; then
		sed -i "/^${dev_id}$/d" "${UBLK_TEST_DIR}/.ublk_devs"
	fi
}

__remove_ublk_dev_return() {
	local dev_id=$1

	_ublk_del_dev "${dev_id}"
	local res=$?
	udevadm settle --timeout=20
	return ${res}
}

__run_io_and_remove()
{
	local dev_id=$1
	local size=$2
	local kill_server=$3

	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=randrw --norandommap --iodepth=256 --size="${size}" --numjobs="$(nproc)" \
		--runtime=20 --time_based > /dev/null 2>&1 &
	fio --name=batchjob --filename=/dev/ublkb"${dev_id}" --ioengine=io_uring \
		--rw=randrw --norandommap --iodepth=256 --size="${size}" \
		--numjobs="$(nproc)" --runtime=20 --time_based \
		--iodepth_batch_submit=32 --iodepth_batch_complete_min=32 \
		--force_async=7 > /dev/null 2>&1 &
	sleep 2
	if [ "${kill_server}" = "yes" ]; then
		local state
		state=$(__ublk_kill_daemon "${dev_id}" "DEAD")
		if [ "$state" != "DEAD" ]; then
			echo "device isn't dead($state) after killing daemon"
			return 255
		fi
	fi
	if ! __remove_ublk_dev_return "${dev_id}"; then
		echo "delete dev ${dev_id} failed"
		return 255
	fi
	wait
}

run_io_and_remove()
{
	local size=$1
	local dev_id
	shift 1

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	[ "$UBLK_TEST_QUIET" -eq 0 ] && echo "run ublk IO vs. remove device(ublk add $*)"
	if ! __run_io_and_remove "$dev_id" "${size}" "no"; then
		echo "/dev/ublkc$dev_id isn't removed"
		exit 255
	fi
}

run_io_and_kill_daemon()
{
	local size=$1
	local dev_id
	shift 1

	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	[ "$UBLK_TEST_QUIET" -eq 0 ] && echo "run ublk IO vs kill ublk server(ublk add $*)"
	if ! __run_io_and_remove "$dev_id" "${size}" "yes"; then
		echo "/dev/ublkc$dev_id isn't removed res ${res}"
		exit 255
	fi
}

run_io_and_recover()
{
	local size=$1
	local action=$2
	local state
	local dev_id

	shift 2
	dev_id=$(_add_ublk_dev "$@")
	_check_add_dev "$TID" $?

	fio --name=job1 --filename=/dev/ublkb"${dev_id}" --ioengine=libaio \
		--rw=randread --iodepth=256 --size="${size}" --numjobs=4 \
		--runtime=20 --time_based > /dev/null 2>&1 &
	sleep 4

	if [ "$action" == "kill_daemon" ]; then
		state=$(__ublk_kill_daemon "${dev_id}" "QUIESCED")
	elif [ "$action" == "quiesce_dev" ]; then
		state=$(__ublk_quiesce_dev "${dev_id}" "QUIESCED")
	fi
	if [ "$state" != "QUIESCED" ]; then
		echo "device isn't quiesced($state) after $action"
		return 255
	fi

	state=$(_recover_ublk_dev -n "$dev_id" "$@")
	if [ "$state" != "LIVE" ]; then
		echo "faile to recover to LIVE($state)"
		return 255
	fi

	if ! __remove_ublk_dev_return "${dev_id}"; then
		echo "delete dev ${dev_id} failed"
		return 255
	fi
	wait
}


_ublk_test_top_dir()
{
	cd "$(dirname "$0")" && pwd
}

METADATA_SIZE_PROG="$(_ublk_test_top_dir)/metadata_size"

_get_metadata_size()
{
	local dev_id=$1
	local field=$2

	"$METADATA_SIZE_PROG" "/dev/ublkb$dev_id" | grep "$field" | grep -o "[0-9]*"
}

UBLK_PROG=$(_ublk_test_top_dir)/kublk
UBLK_TEST_QUIET=1
UBLK_TEST_SHOW_RESULT=1
UBLK_BACKFILES=()
export UBLK_PROG
export UBLK_TEST_QUIET
export UBLK_TEST_SHOW_RESULT
