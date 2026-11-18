#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <unistd.h>

int main(void) {
    /* The initramfs starts with an empty /dev; mount devtmpfs before logging. */
    if (mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, NULL) != 0 &&
        errno != EBUSY) {
        const char message[] = "[Aura OS] warning: could not mount devtmpfs\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
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
    puts("[Aura OS] portable initramfs started");
    puts("AURA_INIT_OK");
    puts("AURA_QEMU_TEST_PASS");

    sync();
    if (reboot(RB_POWER_OFF) != 0) {
        perror("[Aura OS] reboot(RB_POWER_OFF) failed");
    }

    /* A failed poweroff must not make PID 1 exit and panic the kernel. */
    for (;;) {
        pause();
    }
}
