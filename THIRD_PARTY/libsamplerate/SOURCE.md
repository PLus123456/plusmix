# libsamplerate 0.2.2

- 来源：https://github.com/libsndfile/libsamplerate/archive/refs/tags/0.2.2.tar.gz
- SHA-256（tar.gz）：16e881487f184250deb4fcb60432d7556ab12cb58caea71ef23960aec6c0405a
- 拷贝的文件：include/samplerate.h、src/{samplerate.c, src_sinc.c, src_linear.c, src_zoh.c, common.h, fastest_coeffs.h, mid_qual_coeffs.h, high_qual_coeffs.h}
- 本仓库另写：Packages/SwitcherAudio/Sources/CLibSamplerate/config.h（替代上游 CMake 生成的 config.h）
- 上游源文件未改动。
- 用途：每路输入的异步重采样（设计方案 §3.6），比率由速率估计器动态给。
