// ==================== Ray Generation ====================
// 光线生成相关函数：相机光线生成、景深效果等

#ifndef RAYGEN_HLSL
#define RAYGEN_HLSL

#include "common.hlsl"
#include "rng.hlsl"

// ==================== 相机光线生成 ====================

// 生成相机光线（无景深效果）
void GenerateCameraRay(
    uint2 dispatchIndex,
    float2 jitter,
    out float3 rayOrigin,
    out float3 rayDir
) {
    float2 pixel_center = (float2)dispatchIndex + float2(0.5 + jitter.x, 0.5 + jitter.y);
    float2 uv = pixel_center / float2(DispatchRaysDimensions().xy);
    uv.y = 1.0 - uv.y; // 翻转Y轴（屏幕坐标系到NDC坐标系）
    float2 d = uv * 2.0 - 1.0; // 转换到NDC坐标 [-1, 1]

    // 计算初始相机位置和光线方向
    float4 origin4 = mul(camera_info.camera_to_world, float4(0, 0, 0, 1));
    float4 target = mul(camera_info.screen_to_camera, float4(d, 1, 1));
    float4 direction4 = mul(camera_info.camera_to_world, float4(target.xyz, 0));

    rayOrigin = origin4.xyz;
    rayDir = normalize(direction4.xyz);
}

// 生成带景深效果的相机光线
void GenerateCameraRayWithDOF(
    uint2 dispatchIndex,
    float2 jitter,
    inout uint seed,
    out float3 rayOrigin,
    out float3 rayDir
) {
    // 首先生成基础相机光线
    float3 baseRayOrigin, baseRayDir;
    GenerateCameraRay(dispatchIndex, jitter, baseRayOrigin, baseRayDir);
    
    // 如果没有启用景深，直接返回基础光线
    if (camera_info.aperture <= 0.0001) {
        rayOrigin = baseRayOrigin;
        rayDir = baseRayDir;
        return;
    }
    
    // ===== 景深效果 (Depth of Field) =====
    // 计算焦点位置（沿着原始光线方向在焦距处的点）
    float3 focalPoint = baseRayOrigin + baseRayDir * camera_info.focus_distance;
    
    // 在光圈上随机采样一个偏移点（模拟从光圈不同位置发出的光线）
    float2 diskSample = SampleUnitDisk(seed);
    float2 lensOffset = diskSample * camera_info.aperture;
    
    // 计算相机的右向量和上向量（用于在光圈平面上偏移）
    float3 cameraRight = normalize(mul(camera_info.camera_to_world, float4(1, 0, 0, 0)).xyz);
    float3 cameraUp = normalize(mul(camera_info.camera_to_world, float4(0, 1, 0, 0)).xyz);
    
    // 偏移光线原点（模拟从光圈不同位置发出）
    rayOrigin = baseRayOrigin + cameraRight * lensOffset.x + cameraUp * lensOffset.y;
    
    // 重新计算光线方向使其指向焦点（产生景深模糊效果）
    rayDir = normalize(focalPoint - rayOrigin);
}

// ==================== 选择光线生成 ====================

// 生成用于实体选择的光线（无抖动，无景深，确保结果稳定）
void GeneratePickRay(
    uint2 dispatchIndex,
    out float3 rayOrigin,
    out float3 rayDir
) {
    float2 pixel_center0 = (float2)dispatchIndex + float2(0.5, 0.5);
    float2 uv0 = pixel_center0 / float2(DispatchRaysDimensions().xy);
    uv0.y = 1.0 - uv0.y;
    float2 d0 = uv0 * 2.0 - 1.0;
    
    float4 origin40 = mul(camera_info.camera_to_world, float4(0, 0, 0, 1));
    float4 target0 = mul(camera_info.screen_to_camera, float4(d0, 1, 1));
    float4 direction40 = mul(camera_info.camera_to_world, float4(target0.xyz, 0));
    
    rayOrigin = origin40.xyz;
    rayDir = normalize(direction40.xyz);
}

#endif // RAYGEN_HLSL

