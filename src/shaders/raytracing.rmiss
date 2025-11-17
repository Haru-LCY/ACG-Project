// 未击中着色器 (Miss Shader)
#include "ray_payload.hlsl"

[shader("miss")]
void MissMain(inout RayPayload payload) {
	// 简单的程序化天空
	float t = 0.5 * (normalize(WorldRayDirection()).y + 1.0);
	payload.radiance = lerp(float3(1.0, 1.0, 1.0), float3(0.5, 0.7, 1.0), t);
	payload.hit = false;
	payload.material_idx = 0xFFFFFFFF;
}
