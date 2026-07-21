#ifndef AGY_POSIX_H
#define AGY_POSIX_H

#include <sys/file.h>

int agy_flock(int fd, int operation);

#endif /* AGY_POSIX_H */
