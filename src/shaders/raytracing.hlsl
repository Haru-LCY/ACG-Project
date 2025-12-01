// ==================== Ray Tracing ====================
// 路径追踪核心实现

#ifndef RAYTRACING_HLSL
#define RAYTRACING_HLSL

#include "common.hlsl"
#include "rng.hlsl"
#include "bsdf.hlsl"
#include "lighting.hlsl"
#include "skybox.hlsl"

// 简单的光线追踪函数
bool TraceRaySimple(float3 rayOrigin, float3 rayDir, float tMin, float tMax, inout RayPayload payload) {
    RayDesc ray;
    ray.Origin = rayOrigin;
    ray.Direction = normalize(rayDir);
    ray.TMin = tMin;
    ray.TMax = tMax;
    
    payload.hit = false;
    payload.material_idx = 0;
    
    TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);
    
    return payload.hit;
}

// 路径追踪主函数
float3 TracePath(float3 rayOrigin, float3 rayDir, inout uint seed) {
    float3 radiance = float3(0, 0, 0);
    float3 throughput = float3(1, 1, 1);
    
    float3 currentOrigin = rayOrigin;
    float3 currentDir = normalize(rayDir);
    
    for (int bounce = 0; bounce < MAX_PATH_BOUNCES; ++bounce) {
        // 追踪光线
        RayPayload payload;
        bool hit = TraceRaySimple(currentOrigin, currentDir, 0.001, 10000.0, payload);
        
        if (!hit) {
            // 未击中，采样环境光
            float3 envColor = SampleEnvironmentMap(currentDir);
            radiance += throughput * envColor;
            break;
        }
        
        // 获取材质
        Material mat = materials[payload.material_idx];
        float3 hitPos = payload.hit_pos;
        float3 normal = payload.normal;
        float2 uv = payload.uv;
        
        // 计算自发光
        if (mat.emission_strength > 0.001) {
            radiance += throughput * mat.emission_color * mat.emission_strength;
        }
        
        // 计算直接光照（点光源）
        for (uint i = 0; i < (uint)camera_info.num_point_lights; ++i) {
            float3 lightContrib = ComputePointLightContribution(
                hitPos, normal, -currentDir, mat, uv, point_lights[i], seed
            );
            radiance += throughput * lightContrib;
        }
        
        // 计算直接光照（面光源）
        for (uint i = 0; i < (uint)camera_info.num_area_lights; ++i) {
            float3 lightContrib = ComputeAreaLightContribution(
                hitPos, normal, -currentDir, mat, uv, area_lights[i], seed
            );
            radiance += throughput * lightContrib;
        }
        
        // 采样BSDF得到新方向
        float pdf;
        float3 weight;
        float3 newDir = SamplePrincipledBSDF(mat, -currentDir, normal, uv, seed, pdf, weight);
        
        // 更新throughput
        throughput *= weight;
        
        // 俄罗斯轮盘赌终止（在更新throughput之后立即应用）
        // 如果决定终止，应该在除以概率之前就break，避免不必要的计算
        if (bounce > 2) {
            float maxThroughput = max(max(throughput.r, throughput.g), throughput.b);
            float rrProb = min(maxThroughput, 0.95);
            
            // 如果随机数大于继续概率，终止路径
            if (Rand01(seed) > rrProb) {
                break;
            }
            
            // 如果继续追踪，除以概率以保持无偏性
            throughput /= rrProb;
        }
        
        // 准备下一次迭代
        currentOrigin = hitPos + normal * 0.001;
        currentDir = newDir;
    }
    
    return radiance;
}

#endif // RAYTRACING_HLSL

