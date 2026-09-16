#ifndef AGY_POSIX_H
#define AGY_POSIX_H

#include <sys/file.h>

int agy_flock(int fd, int operation);

// Reject writable/non-root path components, symlinks and ACL write grants.
int agy_open_exclusive_policy(void);

#endif /* AGY_POSIX_H */
