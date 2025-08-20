/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * FUSE page cache lock implementation
 */

#ifndef _FS_FUSE_DLM_CACHE_H
#define _FS_FUSE_DLM_CACHE_H

#include <linux/types.h>
#include <linux/rbtree.h>
#include <linux/list.h>
#include <linux/rwsem.h>


struct fuse_inode;

/* Lock modes for page ranges */
enum fuse_page_lock_mode { FUSE_PAGE_LOCK_READ, FUSE_PAGE_LOCK_WRITE };

/* Page cache lock manager */
struct fuse_dlm_cache {
	/* Lock protecting the tree */
	struct rw_semaphore lock;
	/* Interval tree of locked ranges */
	struct rb_root_cached ranges;
};

/* Initialize a page cache lock manager */
int fuse_dlm_cache_init(struct fuse_inode *inode);

/* Clean up a page cache lock manager */
void fuse_dlm_cache_release_locks(struct fuse_inode *inode);

/* Lock a range of pages */
int fuse_dlm_lock_range(struct fuse_inode *inode, uint64_t start,
			uint64_t end, enum fuse_page_lock_mode mode);

/* Unlock a range of pages */
int fuse_dlm_unlock_range(struct fuse_inode *inode, uint64_t start,
			  uint64_t end);

/* Check if a page range is already locked */
bool fuse_dlm_range_is_locked(struct fuse_inode *inode, uint64_t start,
			      uint64_t end, enum fuse_page_lock_mode mode);

/* this is the interface to the filesystem */
void fuse_get_dlm_write_lock(struct file *file, loff_t offset,
				    size_t length);

#endif /* _FS_FUSE_DLM_CACHE_H */
