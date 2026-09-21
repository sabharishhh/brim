#include "BrimScanShim.h"
#include <membership.h>

int brim_getattrlistbulk(int dirfd, struct attrlist *alist, void *attrBuf, size_t bufSize, uint64_t options) {
    return getattrlistbulk(dirfd, alist, attrBuf, bufSize, options);
}

int brim_uid_to_uuid(uid_t uid, unsigned char out[16]) {
    return mbr_uid_to_uuid(uid, out);
}
