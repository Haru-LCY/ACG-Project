// ==================== Ray Tracing Core Logic ====================
// 光线追踪核心逻辑

#ifndef RAYTRACING_HLSL
#define RAYTRACING_HLSL

#include "common.hlsl"
#include "rng.hlsl"
#include "bsdf.hlsl"
#include "lighting.hlsl"

// ACES Tone Mapping (解决过曝/刺眼问题的关键)
float3 ACESFilm(float3 x) {
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// 执行路径追踪
float3 TracePath(float3 rayOrigin, float3 rayDir, inout uint seed) {
    const int MAX_BOUNCES = 8; // 优化：8次弹射足够，平衡质量和性能
    RayPayload payload;
    float3 radiance = float3(0,0,0);
    float3 throughput = float3(1,1,1);
    
    for (int bounce = 0; bounce < MAX_BOUNCES; ++bounce) {
        // 初始化 payload
        payload.hit = false;
        payload.material_idx = 0;
        payload.hit_pos = float3(0,0,0);
        payload.normal = float3(0,1,0);
        
        RayDesc ray;
        ray.Origin = rayOrigin;
        ray.Direction = rayDir;
        ray.TMin = 0.001;
        ray.TMax = 10000.0;
        
        TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);
        
        if (!payload.hit) {
            // Skybox / Environment - 提升环境光亮度
            float3 rayDirNorm = normalize(rayDir);
            float tsky = 0.5 * (rayDirNorm.y + 1.0);
            float3 sky = lerp(float3(0.2, 0.2, 0.25), float3(0.4, 0.5, 0.7), tsky); // 增加环境光亮度
            radiance += throughput * sky;
            break;
        }
        
        Material mat = materials[payload.material_idx];
        float3 N = normalize(payload.normal);
        float3 V = normalize(-rayDir);
        float2 uv = payload.uv;  // 从payload获取UV坐标
        
        // 双面材质处理
        bool entering = dot(N, V) > 0.0;
        if (!entering && mat.transmission < 0.01) N = -N;

        float3 hitPos = payload.hit_pos;
        
        // 获取材质基础颜色（考虑纹理）
        float3 baseColor = GetMaterialBaseColor(mat, uv);
        
        // ===== 直接光照计算 (Direct Lighting / NEE) =====
        bool useNEE = true; // 开启直接光照采样
        
        if (useNEE) {
            // 1. 点光源循环
            const int MAX_POINT_LIGHTS = 16;
            for(int i=0; i<MAX_POINT_LIGHTS; ++i) {
                PointLight pl = point_lights[i];
                if(pl.strength > 0.0) {
                    float3 pointLightContrib = ComputePointLightContribution(hitPos, N, V, mat, uv, pl, seed);
                    radiance += throughput * pointLightContrib;
                }
            }
            
            // 2. 面光源循环
            const int MAX_AREA_LIGHTS = 8; // 假设最多8个
            for (int j = 0; j < MAX_AREA_LIGHTS; ++j) {
                AreaLight al = area_lights[j];
                if (al.strength <= 0.0) continue;
                
                float3 areaLightContrib = ComputeAreaLightContribution(hitPos, N, V, mat, uv, al, seed);
                radiance += throughput * areaLightContrib;
            }
        }

        // ===== 间接光照 (BSDF Sampling / 递归) =====
        
        // 添加自发光
        if (mat.emission_strength > 0.0) {
            radiance += throughput * mat.emission_color * mat.emission_strength;
            break; // 击中发光体，终止路径
        }
        
        // [透明材质逻辑]
        if (mat.transmission > 0.01) {
            float etaI = 1.0;
            float etaT = mat.ior;
            float3 normal = N;
            if (!entering) {
                etaI = mat.ior; etaT = 1.0; normal = -N;
            }
            
            float cosTheta = abs(dot(normal, V));
            float Fr = FresnelDielectric(cosTheta, etaI, etaT);
            
            if (Rand01(seed) < Fr) {
                // 反射
                rayDir = reflect(-V, normal);
                rayOrigin = hitPos + normal * 0.001;
            } else {
                // 折射
                float3 refracted;
                if (Refract(-V, normal, etaI/etaT, refracted)) {
                    rayDir = normalize(refracted);
                    rayOrigin = hitPos - normal * 0.001;
                    // Beer's Law 吸收
                    if (entering) throughput *= mat.transmission_color;
                } else {
                    rayDir = reflect(-V, normal); // 全反射
                    rayOrigin = hitPos + normal * 0.001;
                }
            }
        } 
        // [不透明材质逻辑 - 使用 Principled BSDF]
        else {
            // Sample Principled BSDF
            float pdf_sample;
            float3 bsdf_weight;
            rayDir = SamplePrincipledBSDF(mat, V, N, uv, seed, pdf_sample, bsdf_weight);
            
            // Check if sampling was successful
            if (pdf_sample < 1e-7 || dot(N, rayDir) <= 0.0) {
                break; // Invalid sample or ray goes below surface
            }
            
            rayOrigin = hitPos + N * 0.001;
            throughput *= bsdf_weight;
        }

        // 俄罗斯轮盘赌 (Russian Roulette) 终止路径
        // 改进：使用更智能的生存概率计算
        if (bounce > 2) {
            float survivalProb = max(max(throughput.r, throughput.g), throughput.b);
            survivalProb = clamp(survivalProb, 0.1, 0.95); // 限制在合理范围
            
            if (Rand01(seed) > survivalProb) {
                break; // 终止路径
            }
            throughput /= survivalProb; // 无偏估计
        }
        
        // 额外的安全检查：如果throughput过小，提前终止
        if (max(max(throughput.r, throughput.g), throughput.b) < 0.001) {
            break;
        }
    }
    
    return radiance;
}

#endif // RAYTRACING_HLSL

