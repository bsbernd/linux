/*
  FUSE: Filesystem in Userspace
  Copyright (C) 2001-2008  Miklos Szeredi <miklos@szeredi.hu>

  This program can be distributed under the terms of the GNU GPL.
  See the file COPYING.
*/

#ifndef _FS_FUSE_DEV_I_H
#define _FS_FUSE_DEV_I_H

#include "fuse_i.h"

/* Ordinary requests have even IDs, while interrupts IDs are odd */
#define FUSE_INT_REQ_BIT (1ULL << 0)
#define FUSE_REQ_ID_STEP (1ULL << 1)


#endif


