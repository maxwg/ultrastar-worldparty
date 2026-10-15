/* Test-only SDL mutex/timer shim for the single-threaded production-state harness.
 * No SDL capture/audio backend is implemented here. */
#include <stdint.h>
#include <stdlib.h>
static uint32_t mock_ticks = 1000;
void *SDL_CreateMutex(void) { return calloc(1, 1); }
int SDL_LockMutex(void *m) { (void)m; return 0; }
int SDL_UnlockMutex(void *m) { (void)m; return 0; }
void SDL_DestroyMutex(void *m) { free(m); }
uint32_t SDL_GetTicks(void) { return mock_ticks; }
void SDL_TestSetTicks(uint32_t ticks) { mock_ticks = ticks; }
