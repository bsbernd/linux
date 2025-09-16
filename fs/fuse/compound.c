// SPDX-License-Identifier: GPL-2.0
/*
 * FUSE: Filesystem in Userspace
 * Copyright (C) 2025
 *
 * This file implements compound operations for FUSE, allowing multiple
 * operations to be batched into a single request to reduce round trips
 * between kernel and userspace.
 */

#include "fuse_i.h"

#include <linux/fuse.h>
#include <linux/pagemap.h>
#include <linux/file.h>
#include <linux/sched.h>
#include <linux/namei.h>
#include <linux/slab.h>
#include <linux/xattr.h>
#include <linux/posix_acl.h>
#include <linux/pid_namespace.h>
#include <linux/user_namespace.h>
#include <uapi/linux/fuse.h>

/*
 * Compound request
 */
struct fuse_compound_req
{
	struct fuse_mount *fm;
	struct fuse_compound_in compound_header;
	struct fuse_compound_out result_header;

	size_t total_size;
	char *buffer;
	size_t buffer_pos;
	size_t buffer_size;

	size_t total_expected_out_size;

	/* Operation results for error tracking */
	int op_errors[FUSE_MAX_COMPOUND_OPS];
	struct fuse_args *op_args[FUSE_MAX_COMPOUND_OPS];

	/* Parsing state to avoid double processing */
	bool parsed;
};

struct fuse_compound_req *fuse_compound_alloc(struct fuse_mount *fm,
						uint32_t flags)
{
	struct fuse_compound_req *compound;

	compound = kzalloc(sizeof(*compound), GFP_KERNEL);
	if (!compound)
		return ERR_PTR(-ENOMEM);

	compound->fm = fm;
	compound->compound_header.flags = flags;
	compound->buffer_size = PAGE_SIZE;
	compound->buffer = kvmalloc(compound->buffer_size, GFP_KERNEL);
	if (!compound->buffer) {
		kfree(compound);
		return ERR_PTR(-ENOMEM);
	}
	return compound;
}

/*
 * Free compound request resources
 */
void fuse_compound_free(struct fuse_compound_req *compound)
{
	if (compound) {
		kvfree(compound->buffer);
		kfree(compound);
	}
}

/*
 * Validate compound request structure before sending it out.
 * Returns 0 on success, negative error code on failure.
 */
static int fuse_compound_validate_header(struct fuse_compound_req *compound)
{
	struct fuse_compound_in *in_header = &compound->compound_header;
	size_t offset = 0;
	int i;

	if (compound->buffer_pos > compound->buffer_size)
		return -EINVAL;

	if (!compound || !compound->buffer)
		return -EINVAL;

	if (compound->buffer_pos < sizeof(struct fuse_in_header))
		return -EINVAL;

	if (in_header->count == 0 || in_header->count > FUSE_MAX_COMPOUND_OPS)
		return -EINVAL;

	for (i = 0; i < in_header->count; i++) {
		const struct fuse_in_header *op_hdr;

		if (offset + sizeof(struct fuse_in_header) > compound->buffer_pos) {
			pr_info_ratelimited("FUSE: compound operation %d header extends beyond buffer (offset %zu + header size %zu > buffer pos %zu)\n",
					    i, offset, sizeof(struct fuse_in_header), compound->buffer_pos);
			return -EINVAL;
		}

		op_hdr = (const struct fuse_in_header *)(compound->buffer + offset);

		if (op_hdr->len < sizeof(struct fuse_in_header)) {
			pr_info_ratelimited("FUSE: compound operation %d has invalid length %u (minimum %zu bytes)\n",
					    i, op_hdr->len, sizeof(struct fuse_in_header));
			return -EINVAL;
		}

		if (offset + op_hdr->len > compound->buffer_pos) {
			pr_info_ratelimited("FUSE: compound operation %d extends beyond buffer (offset %zu + length %u > buffer pos %zu)\n",
					    i, offset, op_hdr->len, compound->buffer_pos);
			return -EINVAL;
		}

		if (op_hdr->opcode == 0 || op_hdr->opcode == FUSE_COMPOUND) {
			pr_info_ratelimited("FUSE: compound operation %d has invalid opcode %u (cannot be 0 or FUSE_COMPOUND)\n",
					    i, op_hdr->opcode);
			return -EINVAL;
		}

		if (op_hdr->nodeid == 0) {
			pr_info_ratelimited("FUSE: compound operation %d has invalid node ID 0\n", i);
			return -EINVAL;
		}

		offset += op_hdr->len;
	}

	if (offset != compound->buffer_pos) {
		pr_info_ratelimited("FUSE: compound buffer size mismatch (calculated %zu bytes, actual %zu bytes)\n",
				    offset, compound->buffer_pos);
		return -EINVAL;
	}

	return 0;
}

/*
 * Adds a single operation to the compound request. The operation is serialized
 * into the request buffer with its own fuse_in_header.
 *
 * For operations with page-based payloads (in_pages=true), the page data is
 * ignored at the moment.
 *
 * Returns 0 on success, negative error code on failure.
 */
int fuse_compound_add(struct fuse_compound_req *compound,
		      struct fuse_args *args)
{
	struct fuse_in_header *hdr;
	size_t args_size = 0;
	size_t needed_size;
	size_t expected_out_size = 0;
	size_t page_payload_size = 0;
	int i;

	if (!compound || compound->compound_header.count >= FUSE_MAX_COMPOUND_OPS)
		return -EINVAL;

	/* Calculate input size - handle page-based arguments separately */
	for (i = 0; i < args->in_numargs; i++) {
		/* Last argument with in_pages flag gets data from pages */
		if (unlikely(i == args->in_numargs - 1 && args->in_pages)) {
			/* the data handling is not supported at the moment */
			page_payload_size = args->in_args[i].size;
			args_size += page_payload_size;
		} else {
			args_size += args->in_args[i].size;
		}
	}

	/* Calculate expected output size */
	for (i = 0; i < args->out_numargs; i++)
		expected_out_size += args->out_args[i].size;

	needed_size = sizeof(struct fuse_in_header) + args_size;

	/* Expand buffer if needed */
	if (compound->buffer_pos + needed_size > compound->buffer_size) {
		size_t new_size = max(compound->buffer_size * 2,
				      compound->buffer_pos + needed_size);
		new_size = round_up(new_size, PAGE_SIZE);
		char *new_buffer = kvrealloc(compound->buffer,
						compound->buffer_size,
						new_size, GFP_KERNEL);
		if (!new_buffer)
			return -ENOMEM;
		compound->buffer = new_buffer;
		compound->buffer_size = new_size;
	}

	/* Build request header */
	hdr = (struct fuse_in_header *)(compound->buffer + compound->buffer_pos);
	memset(hdr, 0, sizeof(*hdr));
	hdr->len = needed_size;
	hdr->opcode = args->opcode;
	hdr->nodeid = args->nodeid;
	hdr->uid = from_kuid(compound->fm->fc->user_ns, current_fsuid());
	hdr->gid = from_kgid(compound->fm->fc->user_ns, current_fsgid());
	hdr->pid = pid_nr_ns(task_pid(current), compound->fm->fc->pid_ns);
	hdr->unique = fuse_get_unique(&compound->fm->fc->iq);
	compound->buffer_pos += sizeof(*hdr);

	if (args->in_pages) {
		/* we have external payload,
		 * this is not supported at the moment */
		return -EINVAL;
	}

	/* Copy operation arguments */
	for (i = 0; i < args->in_numargs; i++) {
		memcpy(compound->buffer + compound->buffer_pos,
			args->in_args[i].value, args->in_args[i].size);
		compound->buffer_pos += args->in_args[i].size;
	}

	compound->total_expected_out_size += expected_out_size;

	/* Store args for response parsing */
	compound->op_args[compound->compound_header.count] = args;

	compound->compound_header.count++;
	compound->total_size += needed_size;

	return 0;
}

/*
 * Copy response data to fuse_args structure
 *
 * Returns 0 on success, negative error code on failure.
 */
static void *fuse_copy_response_data(struct fuse_args *args, char *response_data)
{
	size_t copied = 0;
	int arg_idx;

	for (arg_idx = 0; arg_idx < args->out_numargs; arg_idx++) {
		struct fuse_arg current_arg = args->out_args[arg_idx];

		/* Last argument with out_pages: copy to pages */
		if (arg_idx == args->out_numargs - 1 && args->out_pages) {
			/* external payload (in the last out arg)
			 * is not supported at the moment
			 */
			return response_data;
		} else {
			size_t arg_size = current_arg.size;
			if (current_arg.value && arg_size > 0) {
				memcpy(current_arg.value,
				       (char *)response_data + copied,
				       arg_size);
				copied += arg_size;
			}
		}
	}

	return (char*)response_data + copied;
}

int fuse_compound_get_error(struct fuse_compound_req * compound,
			    int op_idx)
{
	return compound->op_errors[op_idx];
}

/*
 * Parse compound response
 *
 * Parses the compound response and populates the original
 * fuse_args structures with the response data. This function is idempotent
 * and can be called multiple times safely.
 *
 * For operations with page-based output (out_pages=true), the response data
 * is ignored at the moment.
 *
 * Returns 0 on success, negative error code on failure.
 */
static int fuse_compound_parse_resp(struct fuse_compound_req *compound,
				uint32_t count, void *response, size_t response_size)
{
	int i;
	int res = 0;

	/* double parsing prevention will be important
	 * for large responses most likely out pages.
	 */
	if (compound->parsed) {
		return 0;
	}

	void *op_out_data = response;
	void *response_end = (char *)response + response_size;

	/* Basic validation */
	if (!response || response_size < sizeof(struct fuse_out_header)) {
		return -EIO;
	}

	/* Parse each operation response */
	for (i = 0;
			i < count && i < compound->result_header.count; i++) {
		struct fuse_out_header *op_hdr = op_out_data;
		struct fuse_args *args = compound->op_args[i];

		/* Validate header length */
		if (op_hdr->len < sizeof(struct fuse_out_header)) {
			return -EIO;
		}

		/* Check if the entire operation response fits in the buffer */
		if ((char *)op_out_data + op_hdr->len > (char *)response_end) {
			return -EIO;
		}

		if (op_hdr->error != 0) {
			compound->op_errors[i] = op_hdr->error;
		}

		/* Copy response data */
		if (args && op_hdr->len > sizeof(struct fuse_out_header)) {
			op_out_data = fuse_copy_response_data(args,
								op_out_data + sizeof(struct fuse_out_header));
		} else {
			/* No response data, just advance past the header */
			op_out_data = (char *)op_out_data + op_hdr->len;
		}
	}

	compound->parsed = true;
	return res;
}

/*
 * Send compound request to userspace
 *
 * Sends the compound request out and parses the response.
 *
 * -> in_arg[0] -> fuse_compound_in (containing mainly count and flags)
 * -> in_arg[1] -> payload
 *		(containing the serialized requests created by fuse_compound_add)
 *
 * On success, the response data is copied to the original fuse_args
 * structures for each operation.
 *
 * Returns 0 on success, or the first error code from any operation.
 * Returns negative error code if the request itself fails.
 */
ssize_t fuse_compound_send(struct fuse_compound_req *compound)
{
	size_t expected_response_size;
	ssize_t ret;
	struct fuse_args args = {
		.opcode = FUSE_COMPOUND,
		.nodeid = 0,
		.in_numargs = 2,
		.out_numargs = 2,
		.out_argvar = true,
	};

	if (!compound) {
		pr_info_ratelimited("FUSE: compound request is NULL in fuse_compound_send\n");
		return -EINVAL;
	}

	if (compound->compound_header.count == 0) {
		pr_info_ratelimited("FUSE: compound request contains no operations\n");
		return -EINVAL;
	}

	/* Calculate response buffer size */
	expected_response_size =
		compound->total_expected_out_size;
	size_t total_buffer_size = expected_response_size +
		(compound->compound_header.count * sizeof(struct fuse_out_header));

	void *resp_payload = kvmalloc(total_buffer_size, GFP_KERNEL | __GFP_ZERO);

	if (!resp_payload)
		return -ENOMEM;
	/* tell the fuse server how much memory we have allocated */
	compound->compound_header.result_size = expected_response_size;

	args.in_args[0].size = sizeof(compound->compound_header);
	args.in_args[0].value = &compound->compound_header;
	args.in_args[1].size = compound->buffer_pos;
	args.in_args[1].value = compound->buffer;

	args.out_args[0].size = sizeof(compound->result_header);
	args.out_args[0].value = &compound->result_header;
	args.out_args[1].size = total_buffer_size;
	args.out_args[1].value = resp_payload;

	/* Validate request */
	ret = fuse_compound_validate_header(compound);
	if (ret)
		goto out;

	ret = fuse_compound_request(compound->fm, &args);
	if (ret == -ENOSYS) {
		goto out;
	}

	size_t actual_response_size = args.out_args[1].size;

	/* Validate response size */
	if (actual_response_size < sizeof(struct fuse_compound_out)) {
		pr_info_ratelimited("FUSE: compound response too small (%zu bytes, minimum %zu bytes)\n",
				    actual_response_size, sizeof(struct fuse_compound_out));
		ret = -EINVAL;
		goto out;
	}

	/* Parse response using actual size */
	ret = fuse_compound_parse_resp(compound,
			compound->result_header.count,
			((char *)resp_payload),
			actual_response_size);
out:
	kvfree(resp_payload);
	return ret;
}
