// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_PROCESS_LAUNCHER_H
#define AXOLOTY_PROCESS_LAUNCHER_H

#include <sys/types.h>

int axoloty_spawn_process(
    const char *executable,
    char *const argv[],
    char *const envp[],
    int stdout_read_fd,
    int stderr_read_fd,
    int stdout_fd,
    int stderr_fd,
    pid_t *pid_out
);

int axoloty_process_exit_code(int status);

int axoloty_enable_child_subreaper(void);

int axoloty_reap_process_group(pid_t process_group_id);

void *axoloty_capture_signal_disposition(int signal_number);
int axoloty_ignore_signal(int signal_number);
int axoloty_restore_signal_disposition(int signal_number, void *saved_disposition);
void axoloty_release_signal_disposition(void *saved_disposition);

#endif
