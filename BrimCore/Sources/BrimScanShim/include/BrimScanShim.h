#ifndef BrimScanShim_h
#define BrimScanShim_h

#include <sys/attr.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdint.h>

// A stable wrapper around getattrlistbulk.
// Returns the number of entries read, or -1 on error (with errno set).
int brim_getattrlistbulk(int dirfd, struct attrlist *alist, void *attrBuf, size_t bufSize, uint64_t options);

#endif /* BrimScanShim_h */
