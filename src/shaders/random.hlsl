// 随机数生成器
#ifndef RANDOM_HLSL
#define RANDOM_HLSL

// 改进的 PCG RNG
uint PCGHash(inout uint state) {
	uint prev = state * 747796405u + 2891336453u;
	uint word = ((prev >> ((prev >> 28u) + 4u)) ^ prev) * 277803737u;
	state = prev;
	return (word >> 22u) ^ word;
}

float Rand01(inout uint state) {
	return float(PCGHash(state)) / 4294967296.0;
}

// 初始化随机种子
uint InitRandomSeed(uint2 pixel, uint sample_count) {
	uint seed = (uint)pixel.x * 1973u + (uint)pixel.y * 9277u + (uint)sample_count * 26699u;
	seed = PCGHash(seed);
	seed = PCGHash(seed);
	return seed;
}

#endif // RANDOM_HLSL
