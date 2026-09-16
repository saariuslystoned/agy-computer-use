#include "include/agy_posix.h"
#include <sys/file.h>

int agy_flock(int fd, int operation) {
    return flock(fd, operation);
}

#include <sys/stat.h>
#include <sys/acl.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static int root_controlled(int fd, int directory) {
    struct stat st;
    if (fstat(fd, &st) || st.st_uid != 0 || (st.st_mode & 0022) ||
        (directory ? !S_ISDIR(st.st_mode) : !S_ISREG(st.st_mode))) return 0;
    acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    if (!acl) return 0;
    acl_entry_t entry;
    int result = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
    while (result == 0) {
        acl_tag_t tag;
        if (acl_get_tag_type(entry, &tag) || tag == ACL_EXTENDED_ALLOW) {
            acl_free(acl); return 0;
        }
        result = acl_get_entry(acl, ACL_NEXT_ENTRY, &entry);
    }
    int end_errno = errno;
    acl_free(acl);
    return result == -1 && end_errno == EINVAL;
}

int agy_open_exclusive_policy(void) {
    const char *components[] = {"Library", "Application Support", "AGYComputerUse", "exclusive-session.json"};
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 || !root_controlled(fd, 1)) { if (fd >= 0) close(fd); return -1; }
    for (int i = 0; i < 4; i++) {
        int next = openat(fd, components[i], O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (i < 3 ? O_DIRECTORY : 0));
        close(fd);
        if (next < 0 || !root_controlled(next, i < 3)) { if (next >= 0) close(next); return -1; }
        fd = next;
    }
    return fd;
}
