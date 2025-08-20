// SPDX-License-Identifier: GPL-2.0-only
/*
 * FUSE page lock cache implementation
 */
#include "fuse_i.h"
#include "fuse_dlm_cache.h"

#include <linux/list.h>
#include <linux/types.h>
#include <linux/slab.h>
#include <linux/interval_tree_generic.h>


/* A range of pages with a lock */
struct fuse_dlm_range {
	/* Interval tree node */
	struct rb_node rb;
	/* Start page offset (inclusive) */
	uint64_t start;
	/* End page offset (inclusive) */
	uint64_t end;
	/* Subtree end value for interval tree */
	uint64_t __subtree_end;
	/* Lock mode */
	enum fuse_page_lock_mode mode;
	/* Temporary list entry for operations */
	struct list_head list;
};

/* Lock modes for FUSE page cache */
#define FUSE_PCACHE_LK_READ 1 /* Shared read lock */
#define FUSE_PCACHE_LK_WRITE 2 /* Exclusive write lock */

/* Interval tree definitions for page ranges */
static inline uint64_t fuse_dlm_range_start(struct fuse_dlm_range *range)
{
	return range->start;
}

static inline uint64_t fuse_dlm_range_last(struct fuse_dlm_range *range)
{
	return range->end;
}

INTERVAL_TREE_DEFINE(struct fuse_dlm_range, rb, uint64_t, __subtree_end,
		    		fuse_dlm_range_start, fuse_dlm_range_last, static,
		    		fuse_page_it);

/**
 * fuse_page_cache_init - Initialize a page cache lock manager
 * @cache: The cache to initialize
 *
 * Initialize a page cache lock manager for a FUSE inode.
 *
 * Return: 0 on success, negative error code on failure
 */
int fuse_dlm_cache_init(struct fuse_inode *inode)
{
	struct fuse_dlm_cache *cache = &inode->dlm_locked_areas;

	if (!cache)
		return -EINVAL;

	init_rwsem(&cache->lock);
	cache->ranges = RB_ROOT_CACHED;

	return 0;
}

/**
 * fuse_page_cache_destroy - Clean up a page cache lock manager
 * @cache: The cache to clean up
 *
 * Release all locks and free all resources associated with the cache.
 */
void fuse_dlm_cache_release_locks(struct fuse_inode *inode)
{
	struct fuse_dlm_cache *cache = &inode->dlm_locked_areas;
	struct fuse_dlm_range *range;
	struct rb_node *node;

	if (!cache)
		return;

	/* Release all locks */
	down_write(&cache->lock);
	while ((node = rb_first_cached(&cache->ranges)) != NULL) {
		range = rb_entry(node, struct fuse_dlm_range, rb);
		fuse_page_it_remove(range, &cache->ranges);
		kfree(range);
	}
	up_write(&cache->lock);
}

/**
 * fuse_dlm_find_overlapping - Find a range that overlaps with [start, end]
 * @cache: The page cache
 * @start: Start page offset
 * @end: End page offset
 *
 * Return: Pointer to the first overlapping range, or NULL if none found
 */
static struct fuse_dlm_range *
fuse_dlm_find_overlapping(struct fuse_dlm_cache *cache, uint64_t start,
			  uint64_t end)
{
	return fuse_page_it_iter_first(&cache->ranges, start, end);
}

/**
 * fuse_page_try_merge - Try to merge ranges within a specific region
 * @cache: The page cache
 * @start: Start page offset
 * @end: End page offset
 *
 * Attempt to merge ranges within and adjacent to the specified region
 * that have the same lock mode.
 */
static void fuse_dlm_try_merge(struct fuse_dlm_cache *cache, uint64_t start,
			       uint64_t end)
{
	struct fuse_dlm_range *range, *next;
	struct rb_node *node;

	if (!cache)
		return;

	/* Find the first range that might need merging */
	range = NULL;
	node = rb_first_cached(&cache->ranges);
	while (node) {
		range = rb_entry(node, struct fuse_dlm_range, rb);
		if (range->end >= start - 1)
			break;
		node = rb_next(node);
	}

	if (!range || range->start > end + 1)
		return;

	/* Try to merge ranges in and around the specified region */
	while (range && range->start <= end + 1) {
		/* Get next range before we potentially modify the tree */
		next = NULL;
		if (rb_next(&range->rb)) {
			next = rb_entry(rb_next(&range->rb),
					struct fuse_dlm_range, rb);
		}

		/* Try to merge with next range if adjacent and same mode */
		if (next && range->mode == next->mode &&
		    range->end + 1 == next->start) {
			/* Merge ranges */
			range->end = next->end;

			/* Remove next from tree */
			fuse_page_it_remove(next, &cache->ranges);
			kfree(next);

			/* Continue with the same range */
			continue;
		}

		/* Move to next range */
		range = next;
	}
}

/**
 * fuse_dlm_lock_range - Lock a range of pages
 * @cache: The page cache
 * @start: Start page offset
 * @end: End page offset
 * @mode: Lock mode (read or write)
 *
 * Add a locked range on the specified range of pages.
 * If parts of the range are already locked, only add the remaining parts.
 * For overlapping ranges, handle lock compatibility:
 * - READ locks are compatible with existing READ locks
 * - READ locks are compatible with existing WRITE locks (downgrade not needed)
 * - WRITE locks need to upgrade existing READ locks
 *
 * Return: 0 on success, negative error code on failure
 */
int fuse_dlm_lock_range(struct fuse_inode *inode, uint64_t start,
			uint64_t end, enum fuse_page_lock_mode mode)
{
	struct fuse_dlm_cache *cache = &inode->dlm_locked_areas;
	struct fuse_dlm_range *range, *new_range, *next;
	int lock_mode;
	int ret = 0;
	LIST_HEAD(to_lock);
	LIST_HEAD(to_upgrade);
	uint64_t current_start = start;

	if (!cache || start > end)
		return -EINVAL;

	/* Convert to lock mode */
	lock_mode = (mode == FUSE_PAGE_LOCK_READ) ? FUSE_PCACHE_LK_READ :
						    FUSE_PCACHE_LK_WRITE;

	down_write(&cache->lock);

	/* Find all ranges that overlap with [start, end] */
	range = fuse_page_it_iter_first(&cache->ranges, start, end);
	while (range) {
		/* Get next overlapping range before we potentially modify the tree */
		next = fuse_page_it_iter_next(range, start, end);

		/* Check lock compatibility */
		if (lock_mode == FUSE_PCACHE_LK_WRITE &&
		    lock_mode != range->mode) {
			/* we own the lock but have to update it. */
			list_add_tail(&range->list, &to_upgrade);
		}
		/* If WRITE lock already exists - nothing to do */

		/* If there's a gap before this range, we need to add the missing range */
		if (current_start < range->start) {
			new_range = kmalloc(sizeof(*new_range), GFP_KERNEL);
			if (!new_range) {
				ret = -ENOMEM;
				goto out_free;
			}

			new_range->start = current_start;
			new_range->end = range->start - 1;
			new_range->mode = lock_mode;
			INIT_LIST_HEAD(&new_range->list);

			list_add_tail(&new_range->list, &to_lock);
		}

		/* Move current_start past this range */
		current_start = max(current_start, range->end + 1);

		/* Move to next range */
		range = next;
	}

	/* If there's a gap after the last range to the end, extend the range */
	if (current_start <= end) {
		new_range = kmalloc(sizeof(*new_range), GFP_KERNEL);
		if (!new_range) {
			ret = -ENOMEM;
			goto out_free;
		}

		new_range->start = current_start;
		new_range->end = end;
		new_range->mode = lock_mode;
		INIT_LIST_HEAD(&new_range->list);

		list_add_tail(&new_range->list, &to_lock);
	}

	/* update locks, if any lock is in this list it has the wrong mode */
	list_for_each_entry(range, &to_upgrade, list) {
		/* Update the lock mode */
		range->mode = lock_mode;
	}

	/* Add all new ranges to the tree */
	list_for_each_entry(new_range, &to_lock, list) {
		/* Add to interval tree */
		fuse_page_it_insert(new_range, &cache->ranges);
	}

	/* Try to merge adjacent ranges with the same mode */
	fuse_dlm_try_merge(cache, start, end);

	up_write(&cache->lock);
	return 0;

out_free:
	/* Free any ranges we allocated but didn't insert */
	while (!list_empty(&to_lock)) {
		new_range =
			list_first_entry(&to_lock, struct fuse_dlm_range, list);
		list_del(&new_range->list);
		kfree(new_range);
	}

	/* Restore original lock modes for any partially upgraded locks */
	list_for_each_entry(range, &to_upgrade, list) {
		if (lock_mode == FUSE_PCACHE_LK_WRITE) {
			/* We upgraded this lock but failed later, downgrade it back */
			range->mode = FUSE_PCACHE_LK_READ;
		}
	}

	up_write(&cache->lock);
	return ret;
}

/**
 * fuse_dlm_punch_hole - Punch a hole in a locked range
 * @cache: The page cache
 * @start: Start page offset of the hole
 * @end: End page offset of the hole
 *
 * Create a hole in a locked range by splitting it into two ranges.
 *
 * Return: 0 on success, negative error code on failure
 */
static int fuse_dlm_punch_hole(struct fuse_dlm_cache *cache, uint64_t start,
			       uint64_t end)
{
	struct fuse_dlm_range *range, *new_range;
	int ret = 0;

	if (!cache || start > end)
		return -EINVAL;

	/* Find a range that contains [start, end] */
	range = fuse_dlm_find_overlapping(cache, start, end);
	if (!range) {
		ret = -EINVAL;
		goto out;
	}

	/* If the hole is at the beginning of the range */
	if (start == range->start) {
		range->start = end + 1;
		goto out;
	}

	/* If the hole is at the end of the range */
	if (end == range->end) {
		range->end = start - 1;
		goto out;
	}

	/* The hole is in the middle, need to split */
	new_range = kmalloc(sizeof(*new_range), GFP_KERNEL);
	if (!new_range) {
		ret = -ENOMEM;
		goto out;
	}

	/* Copy properties from original range */
	*new_range = *range;
	INIT_LIST_HEAD(&new_range->list);

	/* Adjust ranges */
	new_range->start = end + 1;
	range->end = start - 1;

	/* Update interval tree */
	fuse_page_it_remove(range, &cache->ranges);
	fuse_page_it_insert(range, &cache->ranges);
	fuse_page_it_insert(new_range, &cache->ranges);

out:
	return ret;
}

/**
 * fuse_dlm_unlock_range - Unlock a range of pages
 * @cache: The page cache
 * @start: Start page offset
 * @end: End page offset
 *
 * Release locks on the specified range of pages.
 * Note that if start and end are set to zero the cache is destroyed.
 *
 * Return: 0 on success, negative error code on failure
 */
int fuse_dlm_unlock_range(struct fuse_inode *inode,
						uint64_t start, uint64_t end)
{
	struct fuse_dlm_cache *cache = &inode->dlm_locked_areas;
	struct fuse_dlm_range *range, *next;
	int ret = 0;

	if (!cache)
		return -EINVAL;

	if (start == 0 && end == 0) {
		fuse_dlm_cache_release_locks(inode);
		return 0;
	}

	down_write(&cache->lock);

	/* Find all ranges that overlap with [start, end] */
	range = fuse_page_it_iter_first(&cache->ranges, start, end);
	while (range) {
		/* Get next overlapping range before we potentially modify the tree */
		next = fuse_page_it_iter_next(range, start, end);

		/* Check if we need to punch a hole */
		if (start > range->start && end < range->end) {
			/* Punch a hole in the middle */
			ret = fuse_dlm_punch_hole(cache, start, end);
			if (ret)
				goto out;
			/* After punching a hole, we're done */
			break;
		} else if (start > range->start) {
			/* Adjust the end of the range */
			range->end = start - 1;
		} else if (end < range->end) {
			/* Adjust the start of the range */
			range->start = end + 1;
		} else {
			/* Complete overlap, remove the range */
			fuse_page_it_remove(range, &cache->ranges);
			kfree(range);
		}

		range = next;
	}

out:
	up_write(&cache->lock);
	return ret;
}

/**
 * fuse_dlm_range_is_locked - Check if a page range is already locked
 * @cache: The page cache
 * @start: Start page offset
 * @end: End page offset
 * @mode: Lock mode to check for (or NULL to check for any lock)
 *
 * Check if the specified range of pages is already locked.
 * The entire range must be locked for this to return true.
 *
 * Return: true if the entire range is locked, false otherwise
 */
bool fuse_dlm_range_is_locked(struct fuse_inode *inode, uint64_t start,
			      uint64_t end, enum fuse_page_lock_mode mode)
{
	struct fuse_dlm_cache *cache = &inode->dlm_locked_areas;
	struct fuse_dlm_range *range;
	int lock_mode = 0;
	uint64_t current_start = start;

	if (!cache || start > end)
		return false;

	/* Convert to lock mode if specified */
	if (mode == FUSE_PAGE_LOCK_READ)
		lock_mode = FUSE_PCACHE_LK_READ;
	else if (mode == FUSE_PAGE_LOCK_WRITE)
		lock_mode = FUSE_PCACHE_LK_WRITE;

	down_read(&cache->lock);

	/* Find the first range that overlaps with [start, end] */
	range = fuse_dlm_find_overlapping(cache, start, end);

	/* Check if the entire range is covered */
	while (range && current_start <= end) {
		/* If we're checking for a specific mode, verify it matches */
		if (lock_mode && range->mode != lock_mode) {
			/* Wrong lock mode */
			up_read(&cache->lock);
			return false;
		}

		/* Check if there's a gap before this range */
		if (current_start < range->start) {
			/* Found a gap */
			up_read(&cache->lock);
			return false;
		}

		/* Move current_start past this range */
		current_start = range->end + 1;

		/* Get next overlapping range */
		range = fuse_page_it_iter_next(range, start, end);
	}

	/* Check if we covered the entire range */
	if (current_start <= end) {
		/* There's a gap at the end */
		up_read(&cache->lock);
		return false;
	}

	up_read(&cache->lock);
	return true;
}

/**
 * request a dlm lock from the fuse server
 */
void fuse_get_dlm_write_lock(struct file *file, loff_t offset,
				    size_t length)
{
	struct fuse_file *ff = file->private_data;
	struct inode *inode = file_inode(file);
	struct fuse_conn *fc = get_fuse_conn(inode);
	struct fuse_inode *fi = get_fuse_inode(inode);
	struct fuse_mount *fm = ff->fm;
	uint64_t end = (offset + length - 1) | (PAGE_SIZE - 1);

	/* note that the offset and length don't have to be page aligned here
     * but since we only get here on writeback caching we will send out
	 * page aligned requests */
	offset &= PAGE_MASK;

	FUSE_ARGS(args);
	struct fuse_dlm_lock_in inarg;
	struct fuse_dlm_lock_out outarg;
	int err;

	/* note that this can be run from different processes
	 * at the same time. It is intentionally not protected
	 * since a DLM implementation in the FUSE server should take care
	 * of any races in lock requests */
	if (fuse_dlm_range_is_locked(fi, offset,
				    end, FUSE_PAGE_LOCK_WRITE))
		return; /* we already have this area locked */

	memset(&inarg, 0, sizeof(inarg));
	inarg.fh = ff->fh;

	inarg.start = offset;
	inarg.end = end;
	inarg.type = FUSE_DLM_LOCK_WRITE;

	args.opcode = FUSE_DLM_WB_LOCK;
	args.nodeid = get_node_id(inode);
	args.in_numargs = 1;
	args.in_args[0].size = sizeof(inarg);
	args.in_args[0].value = &inarg;
	args.out_numargs = 1;
	args.out_args[0].size = sizeof(outarg);
	args.out_args[0].value = &outarg;
	err = fuse_simple_request(fm, &args);
	if (err == -ENOSYS) {
		/* fuse server does not support dlm, save the info */
		fc->dlm = 0;
		return;
	}

	if (err)
		return;
	else
		if (inarg.start < outarg.start ||
		    inarg.end > outarg.end) {
			/* fuse server is seriously broken */
			pr_warn("fuse: dlm lock request for %llu:%llu returned %llu:%llu bytes\n",
				inarg.start, inarg.end, outarg.start, outarg.end);
			fuse_abort_conn(fc);
			return;
		} else {
			/* ignore any errors here, there is no way we can react appropriately */
			fuse_dlm_lock_range(fi, outarg.start,
					    		outarg.end,
					    		FUSE_PAGE_LOCK_WRITE);
		}
}
