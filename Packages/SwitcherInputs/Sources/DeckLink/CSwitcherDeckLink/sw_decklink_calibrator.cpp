// 硬件参考钟 ↔ host time 的一阶滤波校准器（方法见 sw_decklink.h 对应节）。纯数学，SDK 不在也编。
#include "sw_decklink.h"

#include <cmath>
#include <cstdlib>

extern "C" {

void sw_decklink_calibrator_init(sw_decklink_calibrator* c, int32_t shift) {
    if (!c) return;
    c->offset_ns = 0;
    c->shift = (shift <= 0 || shift > 20) ? 5 : shift;
    c->samples = 0;
    c->last_residual_ns = 0;
    c->max_abs_residual_ns = 0;
    c->sum_sq_residual = 0;
}

int64_t sw_decklink_calibrator_observe(sw_decklink_calibrator* c, int64_t host_now_ns, int64_t hw_now_ns) {
    if (!c) return 0;
    const int64_t ok = host_now_ns - hw_now_ns;
    if (c->samples == 0) {
        c->offset_ns = ok;
        c->samples = 1;
        c->last_residual_ns = 0;
        return 0;
    }
    const int64_t residual = ok - c->offset_ns;
    // 向零取整的移位：负残差也对称
    const int64_t step = residual >= 0 ? (residual >> c->shift) : -((-residual) >> c->shift);
    c->offset_ns += step;
    c->samples += 1;
    c->last_residual_ns = residual;
    const int64_t a = residual < 0 ? -residual : residual;
    if (a > c->max_abs_residual_ns) c->max_abs_residual_ns = a;
    c->sum_sq_residual += (double)residual * (double)residual;
    return residual;
}

int64_t sw_decklink_calibrator_map(const sw_decklink_calibrator* c, int64_t hw_time_ns) {
    return c ? hw_time_ns + c->offset_ns : hw_time_ns;
}

double sw_decklink_calibrator_residual_rms(const sw_decklink_calibrator* c) {
    if (!c || c->samples <= 1) return 0;
    return std::sqrt(c->sum_sq_residual / (double)(c->samples - 1));
}

}  // extern "C"
