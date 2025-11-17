// PBR 着色函数
#ifndef PBR_SHADING_HLSL
#define PBR_SHADING_HLSL

#include "material.hlsl"
#include "fresnel.hlsl"
#include "sampling.hlsl"
#include "constants.hlsl"

// PBR 着色和下一条光线生成
void ComputePBRBounce(
	in Material mat,
	in float3 hitPos,
	in float3 normal,
	in float3 rayDir,
	inout uint seed,
	out float3 newRayOrigin,
	out float3 newRayDir,
	out float3 attenuation
) {
	float3 N = normalize(normal);
	float3 V = normalize(-rayDir);
	
	// 确保法线朝向视线
	if (dot(N, V) < 0.0) N = -N;
	
	// 计算 Fresnel 和镜面反射概率
	float3 F0 = lerp(float3(0.04, 0.04, 0.04), mat.base_color, mat.metallic);
	float cosTheta = max(dot(N, V), 0.0);
	float3 F = FresnelSchlick(cosTheta, F0);
	float specularProb = (F.x + F.y + F.z) / 3.0;
	specularProb = lerp(specularProb, 1.0, mat.metallic);
	
	// 选择镜面反射或漫反射
	float rselect = Rand01(seed);
	if (rselect < specularProb) {
		// 镜面反射
		float3 perfectReflect = reflect(-V, N);
		if (mat.roughness < 0.01) {
			newRayDir = perfectReflect;
		} else {
			float3 perturbedDir = SampleCosineHemisphere(perfectReflect, seed);
			newRayDir = normalize(lerp(perfectReflect, perturbedDir, mat.roughness));
		}
		newRayOrigin = hitPos + N * EPSILON;
		attenuation = F / max(specularProb, 0.001);
	} else {
		// 漫反射
		newRayDir = SampleCosineHemisphere(N, seed);
		newRayOrigin = hitPos + N * EPSILON;
		attenuation = mat.base_color * (1.0 - F) / max(1.0 - specularProb, 0.001);
	}
}

// Russian Roulette 路径终止
bool RussianRoulette(float3 throughput, int bounce, inout uint seed) {
	if (bounce >= 2) {
		float p = max(max(throughput.x, throughput.y), throughput.z);
		p = min(p, 0.95);
		if (Rand01(seed) > p) {
			return true; // 终止路径
		}
	}
	return false; // 继续追踪
}

#endif // PBR_SHADING_HLSL
