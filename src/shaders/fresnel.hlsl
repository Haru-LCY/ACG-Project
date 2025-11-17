// Fresnel 相关函数
#ifndef FRESNEL_HLSL
#define FRESNEL_HLSL

// Schlick Fresnel 近似
float3 FresnelSchlick(float cosTheta, float3 F0) {
	return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

#endif // FRESNEL_HLSL
