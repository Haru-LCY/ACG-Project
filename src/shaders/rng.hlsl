// ==================== Random Number Generation ====================
// 随机数生成相关函数

#ifndef RNG_HLSL
#define RNG_HLSL

#include "common.hlsl"

// 改进的 PCG 随机数生成器（哈希函数）
uint PCGHash(inout uint state) {
	uint prev = state * 747796405u + 2891336453u;
	uint word = ((prev >> ((prev >> 28u) + 4u)) ^ prev) * 277803737u;
	state = prev;
	return (word >> 22u) ^ word;
}

// 生成 [0, 1) 范围的随机浮点数
float Rand01(inout uint state) {
	return float(PCGHash(state)) / 4294967296.0;
}

// 在光圈上均匀采样一个点(用于景深效果)
// 返回一个在单位圆盘内的随机点
float2 SampleUnitDisk(inout uint seed) {
    float r = sqrt(Rand01(seed));
    float theta = 2.0 * PI * Rand01(seed);
    return float2(r * cos(theta), r * sin(theta));
}

#endif // RNG_HLSL

