// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "AxolotyProcessLauncher.h"

#include <spawn.h>
#include <stdlib.h>
#include <signal.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
#include <errno.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

int axoloty_spawn_process(
    const char *executable,
    char *const argv[],
    char *const envp[],
    int stdout_read_fd,
    int stderr_read_fd,
    int stdout_fd,
    int stderr_fd,
    pid_t *pid_out
) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) return result;

    result = posix_spawn_file_actions_adddup2(&actions, stdout_fd, STDOUT_FILENO);
    if (result == 0 && stdout_fd != STDOUT_FILENO) {
        result = posix_spawn_file_actions_addclose(&actions, stdout_fd);
    }
    if (result == 0) {
        result = posix_spawn_file_actions_adddup2(&actions, stderr_fd, STDERR_FILENO);
    }
    if (result == 0 && stderr_fd != STDERR_FILENO && stderr_fd != stdout_fd) {
        result = posix_spawn_file_actions_addclose(&actions, stderr_fd);
    }
    if (result == 0 && stdout_read_fd >= 0) {
        result = posix_spawn_file_actions_addclose(&actions, stdout_read_fd);
    }
    if (result == 0 && stderr_read_fd >= 0 && stderr_read_fd != stdout_read_fd) {
        result = posix_spawn_file_actions_addclose(&actions, stderr_read_fd);
    }
    if (result != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return result;
    }

    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return result;
    }

    short flags = POSIX_SPAWN_SETPGROUP;
    result = posix_spawnattr_setflags(&attributes, flags);
    if (result == 0) {
        // A zero pgroup requests a new process group whose ID is the child PID.
        result = posix_spawnattr_setpgroup(&attributes, 0);
    }
    if (result == 0) {
        result = posix_spawnp(pid_out, executable, &actions, &attributes, argv, envp);
    }

    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return result;
}

int axoloty_process_exit_code(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 70;
}

int axoloty_enable_child_subreaper(void) {
#ifdef __linux__
    return prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0);
#else
    return 0;
#endif
}

int axoloty_reap_process_group(pid_t process_group_id) {
    if (process_group_id <= 1) return 0;

    int status = 0;
    int reaped = 0;
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 10 * 1000 * 1000};
    for (int attempt = 0; attempt < 100; attempt += 1) {
        pid_t result;
        do {
            result = waitpid(-process_group_id, &status, WNOHANG);
            if (result > 0) reaped += 1;
        } while (result > 0);
        if (result < 0 && errno == ECHILD) return reaped;
        nanosleep(&delay, NULL);
    }
    return reaped;
}

void *axoloty_capture_signal_disposition(int signal_number) {
    struct sigaction *saved = calloc(1, sizeof(*saved));
    if (saved == NULL || sigaction(signal_number, NULL, saved) != 0) {
        free(saved);
        return NULL;
    }
    return saved;
}

int axoloty_ignore_signal(int signal_number) {
    struct sigaction ignored = {0};
    sigemptyset(&ignored.sa_mask);
    ignored.sa_handler = SIG_IGN;
    return sigaction(signal_number, &ignored, NULL);
}

int axoloty_restore_signal_disposition(int signal_number, void *saved_disposition) {
    if (saved_disposition == NULL) return EINVAL;
    return sigaction(signal_number, (const struct sigaction *)saved_disposition, NULL);
}

void axoloty_release_signal_disposition(void *saved_disposition) {
    free(saved_disposition);
}
