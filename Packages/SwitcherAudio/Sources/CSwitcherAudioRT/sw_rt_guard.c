// sw_rt_guard.c —— 守卫的全局变量本体。
#include "sw_rt_guard.h"
#include "sw_rt_pragma.h"
uintptr_t sw_rt_guard_thread = 0;
uint32_t sw_rt_guard_depth = 0;
uint64_t sw_rt_guard_violations = 0;
