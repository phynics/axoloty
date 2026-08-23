// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The bounded-runtime source is pure Swift. ESP-IDF still requires a bridge
// header for an Embedded Swift component; it also exposes the compile-only
// entry point so the linker retains the specialization probe.
void bounded_portable_runtime_probe(void);
void g1_print(const char *message);
void g1_print_uint(const char *label, unsigned int value);
unsigned int g1_free_internal_heap(void);
unsigned int g1_min_free_internal_heap(void);
unsigned int g1_largest_internal_block(void);
unsigned int g1_main_stack_high_water(void);
unsigned int g1_main_stack_size(void);
unsigned int g1_reset_reason(void);
unsigned int g1_board_revision(void);
unsigned int g1_flash_size(void);
unsigned int g1_time_microseconds(void);
int g1_heap_trace_begin(void);
unsigned int g1_heap_trace_end(void);
