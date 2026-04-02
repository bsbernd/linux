.. SPDX-License-Identifier: GPL-2.0

=======================================
FUSE-over-io-uring design documentation
=======================================

This documentation covers basic details how the fuse
kernel/userspace communication through io-uring is configured
and works. For generic details about FUSE see fuse.rst.

This document also covers the current interface, which is
still in development and might change.

Limitations
===========
As of now not all requests types are supported through io-uring, userspace
is required to also handle requests through /dev/fuse after io-uring setup
is complete. Specifically notifications (initiated from the daemon side)
and interrupts.

Fuse io-uring configuration
===========================

Fuse kernel requests are queued through the classical /dev/fuse
read/write interface - until io-uring setup is complete.

In order to set up fuse-over-io-uring fuse-server (user-space)
needs to submit SQEs (opcode = IORING_OP_URING_CMD) to the /dev/fuse
connection file descriptor. Initial submit is with the sub command
FUSE_URING_REQ_REGISTER, which will just register entries to be
available in the kernel.

Once at least one entry per queue is submitted, kernel starts
to enqueue to ring queues.
Note, every CPU core has its own fuse-io-uring queue.
Userspace handles the CQE/fuse-request and submits the result as
subcommand FUSE_URING_REQ_COMMIT_AND_FETCH - kernel completes
the requests and also marks the entry available again. If there are
pending requests waiting the request will be immediately submitted
to the daemon again.

Initial SQE
-----------::

 |                                    |  FUSE filesystem daemon
 |                                    |
 |                                    |  >io_uring_submit()
 |                                    |   IORING_OP_URING_CMD /
 |                                    |   FUSE_URING_CMD_REGISTER
 |                                    |  [wait cqe]
 |                                    |   >io_uring_wait_cqe() or
 |                                    |   >io_uring_submit_and_wait()
 |                                    |
 |  >fuse_uring_cmd()                 |
 |   >fuse_uring_register()           |


Sending requests with CQEs
--------------------------::

 |                                           |  FUSE filesystem daemon
 |                                           |  [waiting for CQEs]
 |  "rm /mnt/fuse/file"                      |
 |                                           |
 |  >sys_unlink()                            |
 |    >fuse_unlink()                         |
 |      [allocate request]                   |
 |      >fuse_send_one()                     |
 |        ...                                |
 |       >fuse_uring_queue_fuse_req          |
 |        [queue request on fg queue]        |
 |         >fuse_uring_add_req_to_ring_ent() |
 |         ...                               |
 |          >fuse_uring_copy_to_ring()       |
 |          >io_uring_cmd_done()             |
 |       >request_wait_answer()              |
 |         [sleep on req->waitq]             |
 |                                           |  [receives and handles CQE]
 |                                           |  [submit result and fetch next]
 |                                           |  >io_uring_submit()
 |                                           |   IORING_OP_URING_CMD/
 |                                           |   FUSE_URING_CMD_COMMIT_AND_FETCH
 |  >fuse_uring_cmd()                        |
 |   >fuse_uring_commit_fetch()              |
 |    >fuse_uring_commit()                   |
 |     >fuse_uring_copy_from_ring()          |
 |      [ copy the result to the fuse req]   |
 |     >fuse_uring_req_end()                 |
 |      >fuse_request_end()                  |
 |       [wake up req->waitq]                |
 |    >fuse_uring_next_fuse_req              |
 |       [wait or handle next req]           |
 |                                           |
 |       [req->waitq woken up]               |
 |    <fuse_unlink()                         |
 |  <sys_unlink()                            |

Buffer rings
============

Buffer rings have two main advantages:

* Reduced memory usage: payload buffers are pooled and selected on demand
  rather than dedicated per-entry, allowing fewer buffers than entries. This
  infrastructure also allows for future optimizations like incremental buffer
  consumption where non-overlapping parts of a buffer may be used across
  concurrent requests.
* Foundation for pinned buffers: contiguous buffer allocations allow the
  kernel to pin and vmap the entire region, avoiding per-request page
  resolution overhead

At a high-level, this is how fuse uses buffer rings:

* The first REGISTER SQE for a queue creates the queue and sets up the
  buffer ring. The server provides two iovecs: one for headers and one for
  payload buffers. Each entry gets a fixed ID (sqe->buf_index) that maps
  to a specific header slot.
* When a client request arrives, the kernel selects a payload buffer from
  the ring (if the request has copyable data), copies headers and payload
  data, and completes the sqe.
* The buf_id of the selected payload buffer is communicated to the server
  via the fuse_uring_ent_in_out header. The server uses this to locate the
  payload data in its buffer.
* The server processes the request and sends a COMMIT_AND_FETCH SQE with
  the reply. The kernel processes the reply and recycles the buffer.

Visually, this looks like::

 Headers buffer:
 +-----------------------+-----------------------+-----+
 | fuse_uring_req_header | fuse_uring_req_header | ... |
 | [ent 0]               | [ent 1]               |     |
 +-----------------------+-----------------------+-----+
 ^                       ^
 |                       |
 ent 0 header slot       ent 1 header slot
 (sqe->buf_index=0)      (sqe->buf_index=1)

 Payload buffer pool:
 +-----------+-----------+-----------+-----+
 | buf 0     | buf 1     | buf 2     | ... |
 | (buf_size)| (buf_size)| (buf_size)|     |
 +-----------+-----------+-----------+-----+
 selected on demand, recycled after each request

Buffer ring request flow
------------------------::

|  Kernel                                  |  FUSE daemon
|                                          |
|  [client request arrives]                |
|  >fuse_uring_send()                      |
|    [select payload buf from ring]        |
|    >fuse_uring_select_buffer()           |
|    [copy headers to ent's header slot]   |
|    >copy_header_to_ring()                |
|    [copy payload to selected buf]        |
|    >fuse_uring_copy_to_ring()            |
|    [set buf_id in ent_in_out header]     |
|    >io_uring_cmd_done()                  |
|                                          |  [CQE received]
|                                          |  [read headers from header slot]
|                                          |  [read payload from buf_id]
|                                          |  [process request]
|                                          |  [write reply to header slot]
|                                          |  [write reply payload to buf]
|                                          |  >io_uring_submit()
|                                          |   COMMIT_AND_FETCH
|  >fuse_uring_commit_fetch()              |
|    >fuse_uring_commit()                  |
|     [copy reply from ring]               |
|     >fuse_uring_recycle_buffer()         |
|    >fuse_uring_get_next_fuse_req()       |

Pinned buffers
==============

Servers can optionally pin their header and/or payload buffers by setting
FUSE_URING_PINNED_HEADERS and/or FUSE_URING_PINNED_BUFFERS flags. When
set, the kernel pins the user pages and vmaps them during queue setup,
enabling memcpy to/from the kernel virtual address instead of
copy_to_user/copy_from_user.

This avoids the per-request cost of pinning/unpinning user pages and
translating virtual addresses. Buffers must be page-aligned. The pinned pages
are accounted against RLIMIT_MEMLOCK (bypassable with CAP_IPC_LOCK).

Zero-copy
=========

Fuse io-uring zero-copy allows the server to directly read from / write to
the client's pages, bypassing any intermediary buffer copies. This requires
the FUSE_URING_ZERO_COPY flag, buffer rings with pinned headers and buffers,
and CAP_SYS_ADMIN.

The kernel registers the client's underlying pages as a sparse buffer at
the entry's fixed id via io_buffer_register_bvec(). The fuse server can
then perform io_uring read/write operations directly on these pages.
Non-page-backed args (eg out headers) go through the payload buffer as
normal. Pages are unregistered when the request completes.

The request flow for the zero-copy write path (client writes data, server
reads it) is as follows:

Zero-copy write
---------------::
|  Kernel                                   |  FUSE server
|                                           |
|  "write(fd, buf, 1MB)"                    |
|                                           |
|  >sys_write()                             |
|    >fuse_file_write_iter()                |
|      >fuse_send_one()                     |
|        [req->args->in_pages = true]       |
|        [folios hold client write data]    |
|                                           |
|  >fuse_uring_copy_to_ring()               |
|    >copy_header_to_ring(IN_OUT)           |
|      [memcpy fuse_in_header to            |
|       pinned headers buf via kaddr]       |
|    >copy_header_to_ring(OP)               |
|      [memcpy write_in header]             |
|                                           |
|    >fuse_uring_args_to_ring()             |
|      >setup_fuse_copy_state()             |
|        [is_kaddr = true]                  |
|        [skip_folio_copy = true]           |
|                                           |
|      >fuse_uring_set_up_zero_copy()       |
|        [folio_get for each client folio]  |
|        [build bio_vec array from folios]  |
|        >io_buffer_register_bvec()         |
|          [register pages at ent->id]      |
|        [ent->zero_copied = true]          |
|                                           |
|      >fuse_copy_args()                    |
|        [skip_folio_copy => return 0       |
|         for page arg, skip data copy]     |
|                                           |
|    >copy_header_to_ring(RING_ENT)         |
|      [memcpy ent_in_out]                  |
|    >io_uring_cmd_done()                   |
|                                           |
|                                           | [CQE received]
|                                           |
|                                           | [issue io_uring READ at
|                                           |  ent->id]
|                                           | [reads directly from
|                                           | client's pages (ZERO_COPY)]
|                                           |
|                                           | [write data to backing
|                                           | store]
|                                           |  [submit COMMIT AND FETCH]
|                                           |
|  >fuse_uring_commit_fetch()               |
|    >fuse_uring_commit()                   |
|      >fuse_uring_copy_from_ring()         |
|    >fuse_uring_req_end()                  |
|      >io_buffer_unregister(ent->id)       |
|        [unregister sparse buffer]         |
|      >fuse_zero_copy_release()            |
|        [folio_put for each folio]         |
|      [ent->zero_copied = false]           |
|      >fuse_request_end()                  |
|        [wake up client]                   |

The zero-copy read path is analogous.

Some requests may have both page-backed args and non-page-backed args.
For these requests, the page-backed args are zero-copied while the
non-page-backed args are copied to the buffer selected from the buffer
ring:
  zero-copy: pages registered via io_buffer_register_bvec()
  non-page-backed: copied to payload buffer via fuse_copy_args()

For a request whose payload is zero-copied, the registration/unregistration
path looks like:

register:  fuse_uring_set_up_zero_copy()
	     folio_get() for each folio
	     io_buffer_register_bvec(ent->id)

[server accesses pages via io_uring fixed buf at ent->id]

unregister: fuse_uring_req_end()
	      io_buffer_unregister(ent->id)
	      -> fuse_zero_copy_release() callback
		 folio_put() for each folio
