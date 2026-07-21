#include "include/agy_posix.h"
#include <sys/file.h>

int agy_flock(int fd, int operation) {
    return flock(fd, operation);
}
