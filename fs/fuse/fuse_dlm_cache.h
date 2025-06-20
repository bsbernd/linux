/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * FUSE page cache lock implementation
 */

#ifndef _FS_FUSE_PAGE_CACHE_H
#define _FS_FUSE_PAGE_CACHE_H

#include <linux/types.h>
#include <linux/rbtree.h>
#include <linux/list.h>
#include <linux/spinlock.h>

/* Lock modes for page ranges */
enum fuse_page_lock_mode { FUSE_PAGE_LOCK_READ, FUSE_PAGE_LOCK_WRITE };

/* A range of pages with a lock */
struct fuse_dlm_range {
	/* Interval tree node */
	struct rb_node rb;
	/* Start page offset (inclusive) */
	pgoff_t start;
	/* End page offset (inclusive) */
	pgoff_t end;
	/* Subtree end value for interval tree */
	pgoff_t __subtree_end;
	/* Lock mode */
	enum fuse_page_lock_mode mode;
	/* Temporary list entry for operations */
	struct list_head list;
};

/* Page cache lock manager */
struct fuse_dlm_cache {
	/* Lock protecting the tree */
	spinlock_t
		lock; /* mutex? Because conflicting writes might cause spinning */
	/* Interval tree of locked ranges */
	struct rb_root_cached ranges;
};

/* Initialize a page cache lock manager */
int fuse_dlm_cache_init(struct fuse_dlm_cache *cache);

/* Clean up a page cache lock manager */
void fuse_dlm_cache_destroy(struct fuse_dlm_cache *cache);

/* Lock a range of pages */
int fuse_dlm_lock_range(struct fuse_dlm_cache *cache, pgoff_t start,
			pgoff_t end, enum fuse_page_lock_mode mode);

/* Unlock a range of pages */
int fuse_dlm_unlock_range(struct fuse_dlm_cache *cache, pgoff_t start,
			  pgoff_t end);

/* Check if a page range is already locked */
bool fuse_dlm_range_is_locked(struct fuse_dlm_cache *cache, pgoff_t start,
			      pgoff_t end, enum fuse_page_lock_mode mode);

#endif /* _FS_FUSE_PAGE_CACHE_H */
