#define _GNU_SOURCE

#include <errno.h>
#include <dirent.h>
#include <limits.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "root_uuid.h"

static void write_fully(int fd, const char *buffer, size_t length) {
    while (length > 0) {
        ssize_t written = write(fd, buffer, length);
        if (written > 0) {
            buffer += (size_t)written;
            length -= (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
}

static void log_message(const char *message) {
    write_fully(STDOUT_FILENO, message, strlen(message));
    write_fully(STDOUT_FILENO, "\n", 1);
}

static void fail_and_halt(const char *message) {
    log_message(message);
    for (;;) {
        pause();
    }
}

static int mount_if_needed(const char *source, const char *target,
                           const char *filesystem, unsigned long flags,
                           const char *options) {
    if (mount(source, target, filesystem, flags, options) == 0) {
        return 0;
    }
    return errno == EBUSY ? 0 : -1;
}

static int has_kernel_argument(const char *wanted) {
    FILE *cmdline = fopen("/proc/cmdline", "r");
    char buffer[4096];
    char *saveptr = NULL;
    char *token;
    int found = 0;

    if (cmdline == NULL) {
        return 0;
    }
    if (fgets(buffer, sizeof(buffer), cmdline) != NULL) {
        for (token = strtok_r(buffer, " \t\r\n", &saveptr);
             token != NULL;
             token = strtok_r(NULL, " \t\r\n", &saveptr)) {
            if (strcmp(token, wanted) == 0) {
                found = 1;
                break;
            }
        }
    }
    fclose(cmdline);
    return found;
}

static int read_root_uuid_from_cmdline(char uuid[AURA_UUID_STRING_SIZE]) {
    FILE *cmdline = fopen("/proc/cmdline", "r");
    char buffer[4096];
    int result;

    if (cmdline == NULL) {
        return -1;
    }
    if (fgets(buffer, sizeof(buffer), cmdline) == NULL) {
        fclose(cmdline);
        return -1;
    }
    fclose(cmdline);
    result = aura_parse_root_uuid(buffer, uuid);
    return result;
}

static int block_device_matches_uuid(const char *device_path, const char *uuid) {
    unsigned char superblock[AURA_EXT4_SUPERBLOCK_SIZE];
    size_t total = 0;
    int fd = open(device_path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);

    if (fd < 0) {
        return 0;
    }

    while (total < sizeof(superblock)) {
        ssize_t count = pread(
            fd,
            superblock + total,
            sizeof(superblock) - total,
            (off_t)(AURA_EXT4_SUPERBLOCK_OFFSET + total)
        );
        if (count > 0) {
            total += (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        (void)close(fd);
        return 0;
    }

    (void)close(fd);
    return aura_ext4_superblock_matches_uuid(superblock, uuid);
}

static int find_block_device_by_uuid(const char *uuid,
                                     char *device_path,
                                     size_t device_path_size) {
    DIR *blocks = opendir("/sys/class/block");
    struct dirent *entry;
    int found = 0;

    if (blocks == NULL) {
        return -1;
    }

    while ((entry = readdir(blocks)) != NULL) {
        char candidate[PATH_MAX];
        struct stat status;
        int length;

        if (entry->d_name[0] == '.') {
            continue;
        }
        length = snprintf(candidate, sizeof(candidate), "/dev/%s", entry->d_name);
        if (length < 0 || (size_t)length >= sizeof(candidate)) {
            continue;
        }
        if (stat(candidate, &status) != 0 || !S_ISBLK(status.st_mode)) {
            continue;
        }
        if (!block_device_matches_uuid(candidate, uuid)) {
            continue;
        }
        if (found > 0) {
            /* Duplicate filesystem UUIDs are ambiguous; never choose by scan order. */
            found = -2;
            break;
        }

        length = snprintf(device_path, device_path_size, "%s", candidate);
        if (length < 0 || (size_t)length >= device_path_size) {
            found = -1;
            break;
        }
        found = 1;
    }

    (void)closedir(blocks);
    return found;
}

static void wait_for_root_device(char *device_path, size_t device_path_size) {
    const struct timespec delay = {.tv_sec = 0, .tv_nsec = 50000000L};
    char uuid[AURA_UUID_STRING_SIZE];
    int uuid_status = read_root_uuid_from_cmdline(uuid);

    if (uuid_status < 0) {
        fail_and_halt("[Aura OS] ERROR: root= must contain one valid root=UUID= value");
    }

    if (uuid_status == 0) {
        /* Compatibility for older emulator profiles; production tests pass root=UUID=. */
        for (int attempt = 0; attempt < 200; ++attempt) {
            struct stat status;
            if (stat("/dev/vda", &status) == 0 && S_ISBLK(status.st_mode)) {
                (void)snprintf(device_path, device_path_size, "%s", "/dev/vda");
                log_message("AURA_ROOT_DEVICE_LEGACY_FALLBACK");
                return;
            }
            (void)nanosleep(&delay, NULL);
        }
        fail_and_halt("[Aura OS] ERROR: legacy root device /dev/vda did not appear");
    }

    log_message("AURA_ROOT_UUID_REQUESTED");
    for (int attempt = 0; attempt < 200; ++attempt) {
        int result = find_block_device_by_uuid(uuid, device_path, device_path_size);
        if (result > 0) {
            char message[PATH_MAX + 80];
            (void)snprintf(message, sizeof(message),
                           "[Aura OS] selected root filesystem device %s", device_path);
            log_message(message);
            log_message("AURA_ROOT_DEVICE_MATCHED");
            return;
        }
        if (result == -2) {
            fail_and_halt("[Aura OS] ERROR: multiple block devices match root=UUID; refusing ambiguous root selection");
        }
        if (result < 0) {
            fail_and_halt("[Aura OS] ERROR: cannot enumerate /sys/class/block");
        }
        (void)nanosleep(&delay, NULL);
    }

    fail_and_halt("[Aura OS] ERROR: no ext4 block device matched root=UUID after 10 seconds");
}

static void switch_to_debian_rootfs(void) {
    char root_device[PATH_MAX];
    log_message("[Aura OS] persistent-root boot requested");
    wait_for_root_device(root_device, sizeof(root_device));

    /* Rootfs is not pivot_root()-able on the pinned Linux 6.18 kernel.
       Use the traditional switch_root overmount/chroot sequence instead. */
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
        perror("[Aura OS] ERROR: making initramfs mounts private failed");
        fail_and_halt("[Aura OS] ERROR: cannot isolate mount propagation");
    }

    if (mount(root_device, "/newroot", "ext4", MS_RELATIME, NULL) != 0) {
        perror("[Aura OS] ERROR: mounting the selected root device as ext4 failed");
        fail_and_halt("[Aura OS] ERROR: cannot mount the Aura Debian root filesystem");
    }

    if (mount("/dev", "/newroot/dev", NULL, MS_MOVE, NULL) != 0) {
        perror("[Aura OS] ERROR: moving /dev into the new root failed");
        fail_and_halt("[Aura OS] ERROR: cannot prepare /dev in the new root");
    }
    if (mount("/proc", "/newroot/proc", NULL, MS_MOVE, NULL) != 0) {
        perror("[Aura OS] ERROR: moving /proc into the new root failed");
        fail_and_halt("[Aura OS] ERROR: cannot prepare /proc in the new root");
    }
    if (mount("/sys", "/newroot/sys", NULL, MS_MOVE, NULL) != 0) {
        perror("[Aura OS] ERROR: moving /sys into the new root failed");
        fail_and_halt("[Aura OS] ERROR: cannot prepare /sys in the new root");
    }

    /*
     * Do not require the initramfs tree to be empty before switching roots.
     * The overmount below detaches the old initramfs root from the namespace;
     * after chroot() and execve(), the old /init image and tree can be reclaimed.
     * /dev, /proc, or /sys may still contain implementation-specific entries
     * or active references, so rmdir() here is not a correctness condition.
     */

    /* Keep cwd on the new root while moving it over the immutable rootfs. */
    if (chdir("/newroot") != 0) {
        perror("[Aura OS] ERROR: chdir to the new root failed");
        fail_and_halt("[Aura OS] ERROR: cannot enter the new root");
    }
    if (mount("/newroot", "/", NULL, MS_MOVE, NULL) != 0) {
        perror("[Aura OS] ERROR: moving the new root over / failed");
        fail_and_halt("[Aura OS] ERROR: cannot switch to the Debian root filesystem");
    }
    if (chroot(".") != 0) {
        perror("[Aura OS] ERROR: chroot into the new root failed");
        fail_and_halt("[Aura OS] ERROR: cannot enter the Debian root filesystem");
    }
    if (chdir("/") != 0) {
        perror("[Aura OS] ERROR: chdir after switch_root failed");
        fail_and_halt("[Aura OS] ERROR: cannot enter the new system root");
    }

    log_message("[Aura OS] switched to Debian root filesystem; starting systemd");
    (void)setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    (void)setenv("HOME", "/root", 1);
    (void)setenv("TERM", "linux", 1);

    char *const argv[] = {(char *)"init", NULL};
    char *const envp[] = {
        (char *)"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        (char *)"HOME=/root",
        (char *)"TERM=linux",
        NULL
    };
    execve("/sbin/init", argv, envp);

    perror("[Aura OS] ERROR: execve(/sbin/init) failed");
    fail_and_halt("[Aura OS] ERROR: unable to start systemd as PID 1");
}

int main(void) {
    /* Initramfs starts with an empty /dev; mount devtmpfs before opening console. */
    if (mount_if_needed("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755") != 0) {
        const char warning[] = "[Aura OS] warning: could not mount devtmpfs\n";
        write_fully(STDERR_FILENO, warning, sizeof(warning) - 1);
    }

    int console_fd = open("/dev/console", O_RDWR | O_NOCTTY);
    if (console_fd >= 0) {
        (void)dup2(console_fd, STDIN_FILENO);
        (void)dup2(console_fd, STDOUT_FILENO);
        (void)dup2(console_fd, STDERR_FILENO);
        if (console_fd > STDERR_FILENO) {
            (void)close(console_fd);
        }
    }

    (void)setvbuf(stdout, NULL, _IONBF, 0);
    if (mount_if_needed("proc", "/proc", "proc",
                        MS_NOSUID | MS_NOEXEC | MS_NODEV, "hidepid=0") != 0) {
        fail_and_halt("[Aura OS] ERROR: could not mount proc in initramfs");
    }
    if (mount_if_needed("sysfs", "/sys", "sysfs",
                        MS_NOSUID | MS_NOEXEC | MS_NODEV, NULL) != 0) {
        fail_and_halt("[Aura OS] ERROR: could not mount sysfs in initramfs");
    }

    log_message("[Aura OS] portable initramfs started");
    log_message("AURA_INIT_OK");

    if (has_kernel_argument("aura.rootfs=1")) {
        switch_to_debian_rootfs();
    }

    /* Legacy kernel/UEFI smoke tests intentionally run without a root disk. */
    log_message("AURA_QEMU_TEST_PASS");
    sync();
    if (reboot(RB_POWER_OFF) != 0) {
        perror("[Aura OS] reboot(RB_POWER_OFF) failed");
    }

    /* A failed poweroff must not make PID 1 exit and panic the kernel. */
    for (;;) {
        pause();
    }
}
