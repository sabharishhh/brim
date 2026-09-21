#ifndef BrimScanShim_h
#define BrimScanShim_h

#include <sys/attr.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdint.h>

// A stable wrapper around getattrlistbulk.
// Returns the number of entries read, or -1 on error (with errno set).
int brim_getattrlistbulk(int dirfd, struct attrlist *alist, void *attrBuf, size_t bufSize, uint64_t options);

// The directory UUID for a numeric user id, which is what names the files in
// the Background Task Management store. membership.h is not in the Darwin
// module map, so Swift cannot call mbr_uid_to_uuid without this.
// Returns 0 on success.
int brim_uid_to_uuid(uid_t uid, unsigned char out[16]);

#endif /* BrimScanShim_h */
