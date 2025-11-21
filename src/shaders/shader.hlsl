// ==================== Main Shader File ====================
// 主着色器文件，包含所有模块并实现入口点

// 包含所有模块
#include "common.hlsl"
#include "rng.hlsl"
#include "bsdf.hlsl"
#include "lighting.hlsl"
#include "raytracing.hlsl"
#include "geometry.hlsl"
#include "raygen.hlsl"

[shader("raygeneration")] void RayGenMain() {
    uint2 dispatchIndex = DispatchRaysIndex().xy;
    int prev_samples = accumulated_samples[dispatchIndex];
    uint seed = (uint)dispatchIndex.x * 1973u + (uint)dispatchIndex.y * 9277u + (uint)prev_samples * 26699u;
    seed = PCGHash(seed);
    seed = PCGHash(seed);

    int spp = max(1, camera_info.samples_per_pixel);
    float3 radianceSum = float3(0,0,0);
    RayPayload lastPayload; // keep last payload for debug

    // --- Deterministic pick ray for stable entity ID (no jitter, no DOF)
    RayPayload pickPayload;
    pickPayload.hit = false;
    pickPayload.material_idx = 0;    
    {
        float3 pickOrigin, pickDir;
        GeneratePickRay(dispatchIndex, pickOrigin, pickDir);

        RayDesc pickRay;
        pickRay.Origin = pickOrigin;
        pickRay.Direction = pickDir;
        pickRay.TMin = 0.001;
        pickRay.TMax = 10000.0;
        TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, pickRay, pickPayload);
        // Write depth (distance) into the depth buffer (0.0 if no hit)
        float dval = 0.0;
        if (pickPayload.hit) {
            dval = length(pickPayload.hit_pos - pickOrigin);
        }
        depth_output[dispatchIndex] = dval;
    }

    for (int s = 0; s < spp; ++s) {
        // advance RNG for new sample
        seed = PCGHash(seed);
        float jitter_x = Rand01(seed) - 0.5;
        float jitter_y = Rand01(seed) - 0.5;
        float2 jitter = float2(jitter_x, jitter_y);

        // 生成带景深效果的相机光线
        float3 rayOrigin, rayDir;
        GenerateCameraRayWithDOF(dispatchIndex, jitter, seed, rayOrigin, rayDir);

        // 执行路径追踪
        float3 radiance = TracePath(rayOrigin, rayDir, seed);
        
        // accumulate this sample
        radianceSum += radiance;
        lastPayload = pickPayload;
    }
    
    // ================== 最终输出处理 (Tone Mapping) ==================
    
    // 累积颜色
    float4 prev_color = accumulated_color[dispatchIndex];
    // 注意：Radiance 可能非常大 (HDR)，需要累积 HDR 值
    float4 new_sum = prev_color + float4(radianceSum, (float)spp);
    int new_count = prev_samples + spp;
    
    accumulated_color[dispatchIndex] = new_sum;
    accumulated_samples[dispatchIndex] = new_count;
    
    // 计算平均值
    float3 hdrColor = new_sum.rgb / float(new_count);

    // Apply global exposure multiplier from camera settings
    hdrColor *= camera_info.exposure;
    
    // [关键] 应用 Tone Mapping (HDR -> LDR)
    // 这将把 (20, 50, 20) 这样的亮度映射回 (0.9, 1.0, 0.9) 而不是截断
    float3 mappedColor = ACESFilm(hdrColor);
    
    // Gamma 校正
    mappedColor = pow(mappedColor, 1.0 / 2.2);
    
    output[dispatchIndex] = float4(mappedColor, 1.0);
    entity_id_output[dispatchIndex] = pickPayload.hit ? (int)pickPayload.material_idx : -1;
}

[shader("miss")] void MissMain(inout RayPayload payload) {
	float t = 0.5 * (normalize(WorldRayDirection()).y + 1.0);
	payload.radiance = lerp(float3(1.0, 1.0, 1.0), float3(0.5, 0.7, 1.0), t);
	payload.hit = false;
	payload.material_idx = 0xFFFFFFFF;
}

[shader("closesthit")] void ClosestHitMain(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attr) {
	payload.hit = true;
	payload.material_idx = InstanceID();
	payload.primitive_id = PrimitiveIndex();
	payload.barycentrics = attr.barycentrics;
	
	float t = RayTCurrent();
	payload.hit_pos = WorldRayOrigin() + WorldRayDirection() * t;
	
	// 使用物体空间位置计算几何法线
	float3 worldPos = payload.hit_pos;
	float3 objectPos = mul(WorldToObject3x4(), float4(worldPos, 1.0)).xyz;
	
	// 根据实体ID计算几何法线
	uint entity_id = InstanceID();
	float3 objectNormal = ComputeGeometryNormal(entity_id, objectPos);
	
	// 转换到世界空间
	float3x3 objectToWorld = (float3x3)ObjectToWorld3x4();
	payload.normal = normalize(mul(objectToWorld, objectNormal));
	
	// 确保法线朝向光线来源
	if (dot(payload.normal, -WorldRayDirection()) < 0) {
		payload.normal = -payload.normal;
	}
	
	// 根据实体ID计算UV坐标
	payload.uv = ComputeGeometryUV(entity_id, objectPos, payload.normal);
}
