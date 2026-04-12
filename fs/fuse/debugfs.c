// SPDX-License-Identifier: GPL-2.0
/*
 * FUSE: Filesystem in Userspace
 * Copyright (c) 2026 DataDirect Networks.
 */

#include "fuse_i.h"

#include <linux/debugfs.h>
#include <linux/seq_file.h>

#ifdef CONFIG_FUSE_IO_URING
#include "dev_uring_i.h"

static const char *fuse_ring_req_state_name(enum fuse_ring_req_state state)
{
	switch (state) {
	case FRRS_INVALID:
		return "INVALID";
	case FRRS_COMMIT:
		return "COMMIT";
	case FRRS_AVAILABLE:
		return "AVAILABLE";
	case FRRS_FUSE_REQ:
		return "FUSE_REQ";
	case FRRS_USERSPACE:
		return "USERSPACE";
	case FRRS_TEARDOWN:
		return "TEARDOWN";
	case FRRS_RELEASED:
		return "RELEASED";
	default:
		return "UNKNOWN";
	}
}
#endif

static void fuse_debugfs_show_req(struct seq_file *sf, struct fuse_req *req,
				  const char *prefix)
{
	if (!req)
		return;

	seq_printf(sf, "%sreq=%p unique=%llu opcode=%u flags=0x%lx state=",
		   prefix, req, req->in.h.unique, req->in.h.opcode, req->flags);

	if (test_bit(FR_PENDING, &req->flags))
		seq_puts(sf, "PENDING ");
	if (test_bit(FR_SENT, &req->flags))
		seq_puts(sf, "SENT ");
	if (test_bit(FR_WAITING, &req->flags))
		seq_puts(sf, "WAITING ");
	if (test_bit(FR_LOCKED, &req->flags))
		seq_puts(sf, "LOCKED ");
	if (test_bit(FR_ABORTED, &req->flags))
		seq_puts(sf, "ABORTED ");
	if (test_bit(FR_INTERRUPTED, &req->flags))
		seq_puts(sf, "INTERRUPTED ");
	if (test_bit(FR_URING, &req->flags))
		seq_puts(sf, "URING ");
	seq_puts(sf, "\n");

#ifdef CONFIG_FUSE_IO_URING
	if (test_bit(FR_URING, &req->flags))
		seq_printf(sf, "%s  ring_entry=%p ring_queue=%p\n",
			   prefix, req->ring_entry, req->ring_queue);
#endif
}

/* List /dev/fuse device processing queues */
static int fuse_debugfs_list_dev_pqueue(struct seq_file *sf,
					struct fuse_dev *fud)
{
	struct fuse_pqueue *fpq = &fud->pq;
	struct fuse_req *req;
	int total_requests = 0;
	int hash_idx;

	/* IO queue */
	if (!list_empty(&fpq->io)) {
		seq_printf(sf, "/dev/fuse device %p IO queue:\n", fud);
		list_for_each_entry(req, &fpq->io, list) {
			fuse_debugfs_show_req(sf, req, "  ");
			total_requests++;
		}
		seq_puts(sf, "\n");
	}

	/* Processing hash buckets */
	for (hash_idx = 0; hash_idx < FUSE_PQ_HASH_SIZE; hash_idx++) {
		if (list_empty(&fpq->processing[hash_idx]))
			continue;

		if (hash_idx == 0) {
			seq_printf(sf, "/dev/fuse device %p processing:\n",
				   fud);
		}
		list_for_each_entry(req, &fpq->processing[hash_idx], list) {
			fuse_debugfs_show_req(sf, req, "  ");
			total_requests++;
		}
	}
	if (total_requests)
		seq_puts(sf, "\n");

	return total_requests;
}

/* List /dev/fuse requests */
static int fuse_debugfs_list_devfuse_requests(struct seq_file *sf,
					      struct fuse_conn *fc)
{
	struct fuse_iqueue *fiq = &fc->iq;
	struct fuse_dev *fud;
	struct fuse_req *req;
	int total_requests = 0;

	/* Input queue pending requests */
	spin_lock(&fiq->lock);
	if (!list_empty(&fiq->pending)) {
		seq_puts(sf, "/dev/fuse Input Queue:\n");
		list_for_each_entry(req, &fiq->pending, list) {
			fuse_debugfs_show_req(sf, req, "  ");
			total_requests++;
		}
		seq_puts(sf, "\n");
	}
	spin_unlock(&fiq->lock);

	/* Background queue */
	spin_lock(&fc->bg_lock);
	if (!list_empty(&fc->bg_queue)) {
		seq_puts(sf, "Background queue:\n");
		list_for_each_entry(req, &fc->bg_queue, list) {
			fuse_debugfs_show_req(sf, req, "  ");
			total_requests++;
		}
		seq_puts(sf, "\n");
	}
	spin_unlock(&fc->bg_lock);

	/* Per-device processing queues */
	spin_lock(&fc->lock);
	list_for_each_entry(fud, &fc->devices, entry) {
		spin_lock(&fud->pq.lock);
		total_requests += fuse_debugfs_list_dev_pqueue(sf, fud);
		spin_unlock(&fud->pq.lock);
	}
	spin_unlock(&fc->lock);

	return total_requests;
}

#ifdef CONFIG_FUSE_IO_URING
/* Helper to print requests from a list of ring entries */
static int fuse_debugfs_print_ent_reqs(struct seq_file *sf,
				       struct list_head *head,
				       const char *label)
{
	struct fuse_ring_ent *ent;
	int count = 0;

	if (list_empty(head))
		return 0;

	seq_printf(sf, "  %s:\n", label);
	list_for_each_entry(ent, head, list) {
		if (!ent->fuse_req)
			continue;
		fuse_debugfs_show_req(sf, ent->fuse_req, "    ");
		count++;
	}

	return count;
}

/* Helper to print requests from a list of fuse_req */
static int fuse_debugfs_print_req_list(struct seq_file *sf,
				       struct list_head *head,
				       const char *label)
{
	struct fuse_req *req;
	int count = 0;

	if (list_empty(head))
		return 0;

	seq_printf(sf, "  %s:\n", label);
	list_for_each_entry(req, head, list) {
		fuse_debugfs_show_req(sf, req, "    ");
		count++;
	}

	return count;
}

/* List io-uring requests for a single queue */
static int fuse_debugfs_list_uring_queue(struct seq_file *sf,
					 struct fuse_ring_queue *queue,
					 int qid)
{
	int total_requests = 0;

	seq_printf(sf, "IO-uring Queue %d (qid=%u nr_reqs=%u stopped=%d):\n",
		   qid, queue->qid, queue->nr_reqs, queue->stopped);

	total_requests += fuse_debugfs_print_ent_reqs(sf,
					&queue->ent_w_req_queue,
					"Requests in ring entries");
	total_requests += fuse_debugfs_print_ent_reqs(sf,
					&queue->ent_in_userspace,
					"Requests in userspace");
	total_requests += fuse_debugfs_print_req_list(sf,
					&queue->fuse_req_queue,
					"Queued requests (no ring entry)");
	total_requests += fuse_debugfs_print_req_list(sf,
					&queue->fuse_req_bg_queue,
					"Background requests");

	seq_puts(sf, "\n");
	return total_requests;
}

/* List io-uring requests */
static int fuse_debugfs_list_uring_requests(struct seq_file *sf,
					    struct fuse_conn *fc)
{
	struct fuse_ring *ring = fc->ring;
	struct fuse_ring_queue *queue;
	int total_requests = 0;
	int qid;

	if (!ring)
		return 0;

	seq_printf(sf, "IO-uring: max_nr_queues=%zu ready=%d\n\n",
		   ring->max_nr_queues, ring->ready);

	for (qid = 0; qid < ring->max_nr_queues; qid++) {
		queue = READ_ONCE(ring->queues[qid]);
		if (!queue)
			continue;

		spin_lock(&queue->lock);
		total_requests += fuse_debugfs_list_uring_queue(sf, queue,
								qid);
		spin_unlock(&queue->lock);
	}

	return total_requests;
}
#endif

/* List all requests across all sources (/dev/fuse and io-uring) */
static int fuse_debugfs_list_requests_show(struct seq_file *sf, void *priv)
{
	struct fuse_conn *fc = sf->private;
	int total_requests = 0;

	if (!fc) {
		seq_puts(sf, "No fuse_conn\n");
		return 0;
	}

	total_requests += fuse_debugfs_list_devfuse_requests(sf, fc);

#ifdef CONFIG_FUSE_IO_URING
	total_requests += fuse_debugfs_list_uring_requests(sf, fc);
#endif

	seq_printf(sf, "Total requests: %d\n", total_requests);
	return 0;
}

#ifdef CONFIG_FUSE_IO_URING
/* Show io-uring state */
static int fuse_debugfs_uring_state_show(struct seq_file *sf, void *priv)
{
	struct fuse_conn *fc = sf->private;
	struct fuse_ring *ring;
	struct fuse_ring_queue *queue;
	int qid;

	if (!fc) {
		seq_puts(sf, "No fuse_conn\n");
		return 0;
	}

	/* Global io-uring enable state */
	seq_printf(sf, "IO-uring module enabled: %s\n",
		   fuse_uring_enabled() ? "yes" : "no");

	/* Connection-specific state */
	ring = fc->ring;
	seq_printf(sf, "Connection has io-uring: %s\n", fc->io_uring ? "yes" : "no");

	if (fc->io_uring) {
		if (!ring) {
			seq_puts(sf,
				"IO-uring not configured for this connection\n");
			return 0;
		}
	} else {
		return 0;
	}

	/* Ring state */
	seq_printf(sf, "Ring ready: %s\n", ring->ready ? "yes" : "no");
	seq_printf(sf, "Max number of queues: %zu\n", ring->max_nr_queues);
	seq_printf(sf, "Number of NUMA nodes: %d\n", ring->nr_numa_nodes);
	seq_printf(sf, "Max payload size: %zu\n", ring->max_payload_sz);

	/* Per-queue state */
	seq_puts(sf, "Queue states:\n");
	for (qid = 0; qid < ring->max_nr_queues; qid++) {
		queue = READ_ONCE(ring->queues[qid]);
		if (!queue)
			continue;

		spin_lock(&queue->lock);
		seq_printf(sf, "  Queue %d (qid=%u):\n", qid, queue->qid);
		seq_printf(sf, "    stopped: %s\n", queue->stopped ? "yes" : "no");
		seq_printf(sf, "    nr_reqs: %u\n", queue->nr_reqs);
		seq_printf(sf, "    available entries: %zu\n",
			   list_count_nodes(&queue->ent_avail_queue));
		seq_printf(sf, "    entries with requests: %zu\n",
			   list_count_nodes(&queue->ent_w_req_queue));
		seq_printf(sf, "    entries in userspace: %zu\n",
			   list_count_nodes(&queue->ent_in_userspace));
		seq_printf(sf, "    queued requests: %zu\n",
			   list_count_nodes(&queue->fuse_req_queue));
		seq_printf(sf, "    background requests: %zu\n",
			   list_count_nodes(&queue->fuse_req_bg_queue));
		spin_unlock(&queue->lock);
	}

	return 0;
}

/* Helper to print a list of ring entries */
static int fuse_debugfs_print_ent_list(struct seq_file *sf,
					struct list_head *head,
					const char *label,
					bool show_req_details)
{
	struct fuse_ring_ent *ent;
	int count = 0;

	if (list_empty(head))
		return 0;

	seq_printf(sf, "  %s:\n", label);
	list_for_each_entry(ent, head, list) {
		seq_printf(sf, "    ent=%p state=%s cmd=%p fuse_req=%p",
			   ent, fuse_ring_req_state_name(ent->state),
			   ent->cmd, ent->fuse_req);

		if (show_req_details && ent->fuse_req) {
			seq_printf(sf, " unique=%llu opcode=%u",
				   ent->fuse_req->in.h.unique,
				   ent->fuse_req->in.h.opcode);
		}
		seq_puts(sf, "\n");
		count++;
	}

	return count;
}

/* List all ring entries for a single queue */
static int fuse_debugfs_list_queue_entries(struct seq_file *sf,
					   struct fuse_ring_queue *queue,
					   int qid)
{
	int total = 0;

	seq_printf(sf, "Queue %d (qid=%u nr_reqs=%u stopped=%d):\n",
		   qid, queue->qid, queue->nr_reqs, queue->stopped);

	total += fuse_debugfs_print_ent_list(sf, &queue->ent_avail_queue,
					     "Available entries", false);
	total += fuse_debugfs_print_ent_list(sf, &queue->ent_w_req_queue,
					     "Entries with requests", true);
	total += fuse_debugfs_print_ent_list(sf, &queue->ent_in_userspace,
					     "Entries in userspace", true);
	total += fuse_debugfs_print_ent_list(sf, &queue->ent_commit_queue,
					     "Commit queue entries", false);

	seq_puts(sf, "\n");
	return total;
}

/* List all ring entries across all queues */
static int fuse_debugfs_list_ring_entries_show(struct seq_file *sf, void *priv)
{
	struct fuse_conn *fc = sf->private;
	struct fuse_ring *ring;
	struct fuse_ring_queue *queue;
	int qid;
	int total_entries = 0;

	if (!fc) {
		seq_puts(sf, "No fuse_conn\n");
		return 0;
	}

	ring = fc->ring;
	if (!ring) {
		seq_puts(sf, "No io-uring ring configured\n");
		return 0;
	}

	seq_printf(sf, "Ring: max_nr_queues=%zu nr_numa_nodes=%d ready=%d\n\n",
		   ring->max_nr_queues, ring->nr_numa_nodes, ring->ready);

	for (qid = 0; qid < ring->max_nr_queues; qid++) {
		queue = READ_ONCE(ring->queues[qid]);
		if (!queue)
			continue;

		spin_lock(&queue->lock);
		total_entries += fuse_debugfs_list_queue_entries(sf, queue,
								 qid);
		spin_unlock(&queue->lock);
	}

	seq_printf(sf, "Total ring entries: %d\n", total_entries);
	return 0;
}

/* Helper to show a single queue map */
static void fuse_debugfs_show_queue_map(struct seq_file *sf,
					struct fuse_queue_map *q_map,
					size_t max_nr_queues, int node)
{
	int cpu;

	seq_printf(sf, "  Number of queues: %zu\n", q_map->nr_queues);
	seq_printf(sf, "  Registered queue mask: %*pbl\n",
		   cpumask_pr_args(q_map->registered_q_mask));
	seq_puts(sf, "  CPU -> qid:\n");

	for (cpu = 0; cpu < max_nr_queues; cpu++) {
		if (node != -1 && cpu_to_node(cpu) != node)
			continue;
		seq_printf(sf, "    CPU %3d -> qid %3d\n",
			   cpu, q_map->cpu_to_qid[cpu]);
	}
	seq_puts(sf, "\n");
}

/* Show CPU to qid mappings */
static int fuse_debugfs_cpu_qid_map_show(struct seq_file *sf, void *priv)
{
	struct fuse_conn *fc = sf->private;
	struct fuse_ring *ring;
	struct fuse_queue_map *q_map;
	int node;

	if (!fc)
		return 0;

	ring = fc->ring;
	if (!ring)
		return 0;

	if (!ring->ready)
		return 0;

	/* Global CPU to qid mapping */
	seq_puts(sf, "Global CPU to qid mapping:\n");
	fuse_debugfs_show_queue_map(sf, &ring->q_map, ring->max_nr_queues, -1);

	/* Per-NUMA node CPU to qid mappings */
	if (ring->numa_q_map) {
		for (node = 0; node < ring->nr_numa_nodes; node++) {
			q_map = &ring->numa_q_map[node];
			if (!q_map->nr_queues)
				continue;

			seq_printf(sf, "NUMA node %d CPU to qid mapping:\n",
				   node);
			fuse_debugfs_show_queue_map(sf, q_map,
						    ring->max_nr_queues, node);
		}
	}

	return 0;
}
#endif /* CONFIG_FUSE_IO_URING */

static int fuse_debugfs_list_requests_open(struct inode *inode, struct file *file)
{
	return single_open(file, fuse_debugfs_list_requests_show, inode->i_private);
}

static const struct file_operations fuse_debugfs_list_requests_ops = {
	.open = fuse_debugfs_list_requests_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

#ifdef CONFIG_FUSE_IO_URING
static int fuse_debugfs_uring_state_open(struct inode *inode, struct file *file)
{
	return single_open(file, fuse_debugfs_uring_state_show, inode->i_private);
}

static int fuse_debugfs_list_ring_entries_open(struct inode *inode, struct file *file)
{
	return single_open(file, fuse_debugfs_list_ring_entries_show, inode->i_private);
}

static int fuse_debugfs_cpu_qid_map_open(struct inode *inode, struct file *file)
{
	return single_open(file, fuse_debugfs_cpu_qid_map_show, inode->i_private);
}

static const struct file_operations fuse_debugfs_uring_state_ops = {
	.open = fuse_debugfs_uring_state_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

static const struct file_operations fuse_debugfs_list_ring_entries_ops = {
	.open = fuse_debugfs_list_ring_entries_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};

static const struct file_operations fuse_debugfs_cpu_qid_map_ops = {
	.open = fuse_debugfs_cpu_qid_map_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = single_release,
};
#endif /* CONFIG_FUSE_IO_URING */

static struct dentry *fuse_debugfs_root;

int __init fuse_debugfs_init(void)
{
	fuse_debugfs_root = debugfs_create_dir("fuse", NULL);
	return 0;
}

void fuse_debugfs_cleanup(void)
{
	debugfs_remove_recursive(fuse_debugfs_root);
}

void fuse_debugfs_conn_init(struct fuse_conn *fc)
{
	char name[32];

	if (!fuse_debugfs_root)
		return;

	sprintf(name, "%u", MINOR(fc->dev));
	fc->debugfs_dir = debugfs_create_dir(name, fuse_debugfs_root);

	/* Always create list_requests - works for both /dev/fuse and io-uring */
	debugfs_create_file("list_requests", 0444, fc->debugfs_dir, fc,
			    &fuse_debugfs_list_requests_ops);

#ifdef CONFIG_FUSE_IO_URING
	/* Always create io_uring_state to show if io-uring is enabled */
	debugfs_create_file("io_uring_state", 0444, fc->debugfs_dir, fc,
			    &fuse_debugfs_uring_state_ops);
#endif
}

#ifdef CONFIG_FUSE_IO_URING
/* Called when io-uring ring becomes ready */
void fuse_debugfs_uring_register(struct fuse_conn *fc)
{
	if (!fc->debugfs_dir)
		return;

	/* Create list_ring_entries for io-uring */
	debugfs_create_file("list_ring_entries", 0444, fc->debugfs_dir, fc,
			    &fuse_debugfs_list_ring_entries_ops);

	/* Create cpu_qid_map for io-uring */
	debugfs_create_file("cpu_qid_map", 0444, fc->debugfs_dir, fc,
			    &fuse_debugfs_cpu_qid_map_ops);
}
#endif

void fuse_debugfs_conn_cleanup(struct fuse_conn *fc)
{
	debugfs_remove_recursive(fc->debugfs_dir);
	fc->debugfs_dir = NULL;
}
