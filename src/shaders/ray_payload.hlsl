// 光线载荷数据结构
#ifndef RAY_PAYLOAD_HLSL
#define RAY_PAYLOAD_HLSL

struct RayPayload {
	float3 radiance;
	float3 throughput;
	bool hit;
	uint material_idx;
	float3 hit_pos;
	float3 normal;
	float2 barycentrics;
	uint primitive_id;
};

#endif // RAY_PAYLOAD_HLSL
