// 采样函数
#ifndef SAMPLING_HLSL
#define SAMPLING_HLSL

#include "random.hlsl"
#include "constants.hlsl"

// Lambertian 漫反射采样 - 余弦加权半球采样
float3 SampleCosineHemisphere(float3 n, inout uint seed) {
	float u1 = Rand01(seed);
	float u2 = Rand01(seed);
	float r = sqrt(u1);
	float theta = TWO_PI * u2;
	float x = r * cos(theta);
	float y = r * sin(theta);
	float z = sqrt(max(0.0, 1.0 - u1));
	
	// 构建切线空间
	float3 up = abs(n.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
	float3 t = normalize(cross(up, n));
	float3 b = cross(n, t);
	
	return normalize(x * t + y * b + z * n);
}

#endif // SAMPLING_HLSL
