#include "BrimScanShim.h"

int brim_getattrlistbulk(int dirfd, struct attrlist *alist, void *attrBuf, size_t bufSize, uint64_t options) {
    return getattrlistbulk(dirfd, alist, attrBuf, bufSize, options);
}
