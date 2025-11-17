// 环境光/天空盒函数
#ifndef ENVMAP_HLSL
#define ENVMAP_HLSL

// 简单的程序化天空
float3 SampleSky(float3 direction) {
	float3 rayDirNorm = normalize(direction);
	float t = 0.5 * (rayDirNorm.y + 1.0);
	t = smoothstep(0.0, 1.0, t);
	return lerp(float3(1.0, 1.0, 1.0), float3(0.5, 0.7, 1.0), t);
}

#endif // ENVMAP_HLSL
