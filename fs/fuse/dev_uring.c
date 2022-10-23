/*
  FUSE: Filesystem in Userspace
  Copyright (C) 2001-2008  Miklos Szeredi <miklos@szeredi.hu>

  This program can be distributed under the terms of the GNU GPL.
  See the file COPYING.
*/

#include "fuse_i.h"
#include "fuse_dev_i.h"

#include <linux/init.h>
#include <linux/module.h>
#include <linux/poll.h>
#include <linux/sched/signal.h>
#include <linux/uio.h>
#include <linux/miscdevice.h>
#include <linux/pagemap.h>
#include <linux/file.h>
#include <linux/slab.h>
#include <linux/pipe_fs_i.h>
#include <linux/swap.h>
#include <linux/splice.h>
#include <linux/sched.h>
#include <linux/io_uring.h>
#include <linux/mm.h>
#include <asm/io.h>
#include <linux/io_uring.h>



static int fuse_dev_uring_read(struct fuse_ring_req *ring_req);

/**
 * This functions is called _read_ to have it in sync with similar
 * functions that use posix read()/write() IO to /dev/fuse. In the application
 * write path these fuse userspace _reads: data from /dev/fuse. With uring
 * this is a bit confusing, as there is no read involved here.
 */
static int fuse_dev_read_uring_copy_args(struct fuse_ring_req *ring_req,
					 struct fuse_uring_buf_req *buf_req)
{
	struct fuse_conn *fc = ring_req->fc;
	struct fuse_req *req = &ring_req->req;
	struct fuse_args *args = req->args;
	struct fuse_copy_state cs;
	int err;
	int buf_sz = fc->ring.ring_req_size - FUSE_RING_HEADER_BUF_SIZE;

	fuse_copy_init(&cs, 1, NULL);
	cs.is_uring = 1;
	cs.ring.data_seg_ptr = buf_req->data_seg;
	cs.ring.buf_len = buf_sz;

	pr_debug("%s:%d Here buf=%p buf-sz=%d\n",
		 __func__, __LINE__, cs.ring.data_seg_ptr[0].buf, buf_sz);

	err = fuse_copy_args(&cs, args->in_numargs, args->in_pages,
			     (struct fuse_arg *) args->in_args, 0);
	fuse_copy_finish(&cs);

	if (cs.ring.read.nr_seg > 1) {
		/* do_write_buf() in libfuse does not support more than
		 * one segment.
		 * XXX Update libfuse before final uring support and add
		 *     a uring specific handler? Or support with new feature
		 *     flag later on?
		 */
		return -EINVAL;
	}


	buf_req->nr_data_segs = cs.ring.read.nr_seg;
	buf_req->buf_size_used = cs.ring.read.buf_used;

	pr_debug("%s:%d nr-segs=%d seg[0].len=%llu buf-used=%d \n",
		 __func__, __LINE__, buf_req->nr_data_segs,
		 buf_req->data_seg[0].len, buf_req->buf_size_used);

	return err;
}


int fuse_dev_uring_read(struct fuse_ring_req *ring_req)
{
	struct fuse_uring_buf_req *buf_req = ring_req->kbuf;
	struct fuse_req *req = &ring_req->req;
	int err = -EIO;

	pr_debug("%s:%d Here ring-req=%p buf_req=%p state=%d args=%p \n",
		 __func__, __LINE__, ring_req, buf_req, ring_req->state, req->args);

	if (READ_ONCE(ring_req->state) != FUSE_RING_REQ_STATE_REQ) {
		WARN_RATELIMIT(1, "Invalid ring-req state: %d\n",
				ring_req->state);
		goto err;
	}

	err = fuse_dev_read_uring_copy_args(ring_req, buf_req);
	if (err) {
		pr_debug("read_copy failed: %d\n", err);
		goto err;
	}

	pr_debug("%s:%d Here\n", __func__, __LINE__);

	/* ring req go directly into the shared memory buffer
	 *
	 * XXX avoid this have the data for uring immediately in the
	 * shared userspace buffer. Lots of if-conditions in the code,
	 * though */
	buf_req->in = req->in.h;

	pr_debug("%s cmd-done op=%d unique=%llu\n",
		__func__, buf_req->in.opcode, buf_req->in.unique);

	WRITE_ONCE(ring_req->state, FUSE_RING_REQ_STATE_USERSPACE);
	io_uring_cmd_done(ring_req->cmd, 0, 0);

	return 0;

err:
	req->out.h.error = -EIO;
	fuse_request_end(req);
	return err;
}

/**
 *
 * @return 1 if there is an error, 0 otherise
 */
static int fuse_dev_uring_write_is_err(struct fuse_conn *fc,
				       struct fuse_ring_req *ring_req)
{
	struct fuse_uring_buf_req *buf_req = ring_req->kbuf;
	struct fuse_req *req = &ring_req->req;
	struct fuse_out_header *oh = &buf_req->out;
	int err;

	if (oh->unique == 0) {
		/* Not supportd through request based uring, this needs another
		 * ring from user space to kernel
		 */
		pr_warn("Unsupported fuse-notify\n");
		err = -EINVAL;
		goto err;
	}

	if (buf_req->result < 0) {
		err = buf_req->result;
		goto err;
	}

	if (oh->error <= -512 || oh->error > 0) {
		err = -EINVAL;
		goto err;
	}

	if (oh->error) {
		err = oh->error;
		goto err;
	}

	if ((oh->unique & ~FUSE_INT_REQ_BIT) != req->in.h.unique) {

		pr_warn("Unpexted seqno mismatch, expected: %llu got %llu\n",
			req->in.h.unique, oh->unique & ~FUSE_INT_REQ_BIT);
		err = -ENOENT;
		goto err;
	}

	/* Is it an interrupt reply ID?
	 * XXX: Verifiy if right
	 */
	if (oh->unique & FUSE_INT_REQ_BIT) {
		err = 0;
		if (oh->error == -ENOSYS)
			fc->no_interrupt = 1;
		else if (oh->error == -EAGAIN) {
			/* XXX Needs to copy to the next cq and submit it */
			// err = queue_interrupt(req);
			pr_warn("Intrerupt EAGAIN not supported yet");
			err = -EINVAL;
		}

		goto err;
	}

	return 0;

err:
	ring_req->req.out.h.error = err;
	return 1;
}

void fuse_dev_uring_write(struct fuse_dev *fud,
			  struct fuse_ring_req *ring_req)
{
	struct fuse_uring_buf_req *buf_req = ring_req->kbuf;
	struct fuse_req *req = &ring_req->req;
	struct fuse_copy_state cs;
	ssize_t err;

	pr_debug("%s:%d\n", __func__, __LINE__);

	if (fuse_dev_uring_write_is_err(fud->fc, ring_req)) {
		pr_debug("%s:%d Write err\n", __func__, __LINE__);
		fuse_request_end(&ring_req->req);
	}

	fuse_copy_init(&cs, 0, NULL);
	cs.is_uring = true;
	cs.is_uring = 1;

	/* XXX FIXME NOW */
	cs.ring.seg = buf_req->data_seg;
	cs.ring.buf_len = buf_req->buf_size_used;
	cs.ring.next_seg = buf_req->nr_data_segs;

	pr_debug("%s:%d Here buf=%p buf-sz=%zu\n",
		 __func__, __LINE__, cs.ring.seg[0].buf, cs.ring.buf_len);

	err = copy_out_args(&cs, req->args, buf_req->buf_size_used);
	fuse_copy_finish(&cs);

	pr_debug("%s:%d ret=%zd", __func__, __LINE__, err);
	fuse_request_end(&ring_req->req);
}

/**
 * Check if an application command was queued into the list-queue
 *
 * @return 1 if a reqesust was taken from the queue, 0 if the queue was empty
 * the request is send to userspace then, negative values on error
 *
 * negative values for error
 */
static int fuse_dev_uring_fetch_queued(struct fuse_conn *fc,
				struct fuse_ring_req *ring_req)
{
	struct fuse_iqueue *fiq = &fc->iq;
	struct fuse_req *q_req;
	int rc, ret = 0;

	WRITE_ONCE(ring_req->state, FUSE_RING_REQ_STATE_REQ);

	spin_lock(&fiq->lock);
	if (!list_empty(&fiq->pending)) {
		ret = 1;
		q_req = list_entry(fiq->pending.next, struct fuse_req, list);
		clear_bit(FR_PENDING, &q_req->flags);
		list_del_init(&q_req->list);
	}
	spin_unlock(&fiq->lock);
	if (ret == 0)
		goto out;

	/* copy over and release the list-queued object */
	ring_req->req = *q_req;
	fuse_put_request(q_req);

	pr_debug("%s: args=%p ring-args=%p\n",
		 __func__, q_req->args, ring_req->req.args);

	rc = fuse_dev_uring_read(ring_req);
	if (rc) {
		if (unlikely(rc == -ENOENT)) {
			/* ENOENT is specially treated by the caller,
			 * as no reqest in the list, so must not be used here */
			rc = -EIO;
		}

		if (rc > 0) {
			WARN(1, "Unexpected return code: %d", rc);
			rc = -EIO;
		}

		ret = rc;
	}
out:
	return ret;
}

int fuse_dev_uring(struct io_uring_cmd *cmd, unsigned int issue_flags)
{
	const struct fuse_uring_cmd_req *cmd_req =
		(struct fuse_uring_cmd_req *)cmd->cmd;
	struct fuse_dev *fud = fuse_get_dev(cmd->file);
	struct fuse_conn *fc = fud->fc;
	struct fuse_ring_queue *queue;
	struct fuse_ring_req *ring_req;
	u32 cmd_op = cmd->cmd_op;
	int ret = -EINVAL;

	if (!(issue_flags & IO_URING_F_SQE128)) {
		pr_info("qid=%d tag=%d SQE128 not set\n",
			cmd_req->q_id, cmd_req->tag);
		goto out;
	}

	if (cmd_req->q_id >= fc->ring.nr_queues) {
		pr_info("qid=%u > nr-queues=%zu\n",
			cmd_req->q_id, fc->ring.nr_queues);
		goto out;
	}
	queue = &fc->ring.queues[cmd_req->q_id];

	if (cmd_req->tag > fc->ring.queue_depth) {
		pr_info("tag=%u > queue-depth=%zu\n",
			cmd_req->tag, fc->ring.queue_depth);
		goto out;
	}
	ring_req = &queue->ring_req[cmd_req->tag];

	pr_info("%s: received: cmd op %d queue %d (%p) tag %d  (%p) result %d\n",
		 __func__, cmd_op, cmd_req->q_id, queue, cmd_req->tag, ring_req,
		 cmd_req->result);

	switch (cmd_op) {
	case FUSE_URING_REQ_FETCH:

		if (READ_ONCE(ring_req->state) != FUSE_RING_REQ_STATE_INIT) {
			pr_debug("%s: q_id: %d tag: %d invalid req state: %d\n",
				 __func__, cmd_req->q_id, cmd_req->tag,
				 ring_req->state);
			goto out;
		}

		ring_req->cmd = cmd;

		break;

	case FUSE_URING_REQ_COMMIT_AND_FETCH:
		/* user space forgot to send the buffer - invalid command */
		if (!cmd_req->req_buf) {
			goto out;
		}
		if (ring_req->state != FUSE_RING_REQ_STATE_USERSPACE) {
			pr_info("Invalid request state %d, expected %d \n",
				ring_req->state, FUSE_RING_REQ_STATE_USERSPACE);
			goto out;
		}
		ring_req->cmd = cmd;
		WRITE_ONCE(ring_req->state, FUSE_RING_REQ_STATE_COMMIT);

		fuse_dev_uring_write(fud, ring_req);

		break;
	default:
		pr_debug("Unknown uring command %d", cmd_op);
		goto out;
	}

	ret = fuse_dev_uring_fetch_queued(fc, ring_req);

	pr_debug("%s:%d ret=%d", __func__, __LINE__, ret);

	if (ret < 0)
		goto out;

	if (ret == 0)
		WRITE_ONCE(ring_req->state, FUSE_RING_REQ_STATE_WAITING);

	pr_info("%s: %s cmd op %d queue %d tag %d result %d\n",
		 __func__, ret == 0 ? "req ring queued" : "req sent back",
		cmd_op, cmd_req->q_id, cmd_req->tag, ret);

	return -EIOCBQUEUED;

out:
	WRITE_ONCE(ring_req->state, FUSE_RING_REQ_STATE_USERSPACE);
	io_uring_cmd_done(cmd, ret, 0);
	pr_info("%s: req err: op=%d, tag=%d ret=%d io_flags=%x\n",
		 __func__, cmd_op, cmd_req->tag, ret, issue_flags);
	return -EIOCBQUEUED;
}



/**
 * XXX So far only happens on umount, but we need it on daemon exit.
 *     Create a waiting ioctl thread, which does this on exit?
 */
void fuse_destroy_uring(struct fuse_conn *fc)
{

	spin_lock(&fc->ring.lock);
	if (fc->ring.queues) {
		int q_id, tag, state;
		struct fuse_ring_req *req;
		struct fuse_ring_queue *queue;

		for (q_id = 0; q_id < fc->ring.nr_queues; q_id++) {
			queue = &fc->ring.queues[q_id];
			for (tag = 0; tag < fc->ring.queue_depth; tag++) {
				req = &queue->ring_req[tag];
				state = READ_ONCE(req->state);
				pr_debug("qid=%d tag=%d state=%d\n",
					 q_id, tag, state);

				if (state == FUSE_RING_REQ_STATE_WAITING) {
					/* error code should not matter,
					 * but better a code so that userspace
					 * would abort if somehow still alive
					 */
					pr_debug("releasing cmd qid=%d tag=%d\n",
						 q_id, tag);
					io_uring_cmd_done(req->cmd, -EIO, 0);
				}
			}
		}

		kfree(fc->ring.queues);
		fc->ring.queues = NULL;
	}
	spin_unlock(&fc->ring.lock);
}

static int fuse_dev_create_uring_req_mem(struct fuse_ring_req *req, int size)
{
	const int flags = GFP_KERNEL_ACCOUNT | __GFP_ZERO | __GFP_NOWARN | __GFP_COMP;
	req->kbuf = (void *)__get_free_pages(flags, get_order(size));

	return req->kbuf ? 0 : -ENOMEM;
}

int fuse_dev_setup_uring(struct file *file, struct fuse_uring_cfg *cfg)
{
	struct fuse_dev *fud = fuse_get_dev(file);
	struct fuse_conn *fc;
	size_t req_size;
	size_t queue_size;
	int q_id;

	if (fud == NULL)
		return -ENODEV;

	pr_debug("%s flags=%llx nq=%d  per-core=%d qdepth=%d\n",
		 __func__, cfg->compat_flags, cfg->num_queues, cfg->per_core_queue,
		 cfg->queue_depth);

	fc = fud->fc;

	if (cfg->per_core_queue) {
		if (!cpu_possible(cfg->num_queues - 1)) {
			pr_info("per-core-queue, but number of queue "
				"mismatches number of cpus");
			return -EINVAL;
		}
	} else {
		if (cfg->num_queues != 1) {
			pr_info("Per-core-queue not set, expecting a single "
				"queue");
			return -EINVAL;
		}
	}

	if (cfg->mmap_req_size < FUSE_RING_HEADER_BUF_SIZE + PAGE_SIZE) {
		pr_info("Per req mmap size too small (%d), min: %ld\n",
			cfg->mmap_req_size,
			FUSE_RING_HEADER_BUF_SIZE + PAGE_SIZE);
		return -EINVAL;
	}

	req_size = cfg->queue_depth * sizeof(struct fuse_ring_req);
	queue_size = (sizeof(*fc->ring.queues) + req_size) * cfg->num_queues;

	fc->ring.nr_queues = cfg->num_queues;
	fc->ring.queue_depth = cfg->queue_depth;
	fc->ring.per_core_queue = cfg->per_core_queue;
	fc->ring.ring_req_size = cfg->mmap_req_size;
	fc->ring.queues = kcalloc(cfg->num_queues, queue_size, GFP_KERNEL);
	for (q_id = 0; q_id < cfg->num_queues; q_id++) {
		int tag, rc;
		struct fuse_ring_queue *queue = &fc->ring.queues[q_id];
		queue->q_id = q_id;
		queue->fc = fc;
		atomic_set(&queue->req_cnt, -1);

		for (tag = 0; tag < fc->ring.queue_depth; tag++) {
			struct fuse_ring_req *req = &queue->ring_req[tag];
			req->fc = fc;
			req->tag = tag;

			pr_debug("initialize qid=%d tag=%d queue=%p req=%p",
				 q_id, tag, queue, req);

			rc = fuse_dev_create_uring_req_mem(req, cfg->mmap_req_size);
			if (rc != 0)
				return rc; /* XXX free all memory */

			WRITE_ONCE(req->state, FUSE_RING_REQ_STATE_INIT);
		}
	}

	return 0;
}

/**
 * This is mmap for userspace uring
 */
int fuse_dev_ring_mmap(struct file *filp, struct vm_area_struct *vma)
{
	struct fuse_dev *fud = fuse_get_dev(filp);
	struct fuse_conn *fc = fud->fc;
	size_t sz = vma->vm_end - vma->vm_start;
	phys_addr_t pfn;
	int qid, tag, ret = 0;
	loff_t off;
	struct fuse_ring_queue *queue;
	struct fuse_ring_req *req;

	 /* check if uring is configured and if the requested size matches */
	if (fc->ring.nr_queues == 0 || fc->ring.queue_depth == 0 ||
	    sz != fc->ring.ring_req_size) {
		ret = -EINVAL;
		goto out;
	}

	/* offset actually has the specifies which ring request the mmap is for */
	off = vma->vm_pgoff << PAGE_SHIFT;
	qid = off / fc->ring.nr_queues;
	tag = off % fc->ring.queue_depth;

	if (qid > fc->ring.nr_queues)
		return -EINVAL;

	queue = &fc->ring.queues[qid];
	req = &queue->ring_req[tag];

	pfn = virt_to_phys(req->kbuf) >> PAGE_SHIFT;
	ret = remap_pfn_range(vma, vma->vm_start, pfn, sz, vma->vm_page_prot);

out:
	pr_debug("%s: pid %d addr %lx sz %zu qid: %d tag: %d ret %d\n",
		 __func__, current->pid, vma->vm_start, sz, qid, tag, ret);

	return ret;
}


