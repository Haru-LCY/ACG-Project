// ==================== Ray Tracing Core Logic ====================
// 光线追踪核心逻辑

#ifndef RAYTRACING_HLSL
#define RAYTRACING_HLSL

#include "common.hlsl"
#include "rng.hlsl"
#include "bsdf.hlsl"
#include "lighting.hlsl"
#include "motion_blur.hlsl"
#include "skybox.hlsl"

// ACES Tone Mapping (解决过曝/刺眼问题的关键)
float3 ACESFilm(float3 x) {
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// 简单的光线追踪函数，直接使用硬件加速的 TraceRay
bool TraceRaySimple(float3 rayOrigin, float3 rayDir, float tMin, float tMax, inout RayPayload payload) {
    RayDesc ray;
    ray.Origin = rayOrigin;
    ray.Direction = rayDir;
    ray.TMin = tMin;
    ray.TMax = tMax;
    
    payload.hit = false;
    TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);
    
    return payload.hit;
}

// 执行路径追踪（支持物体运动模糊）
// 物体运动模糊原理：对于有速度的物体，通过多采样在时间域上分散，
// 让物体在运动方向上产生模糊效果。
// 
// 关键改进：在击中有速度的物体后，我们将该物体的颜色/光照贡献
// 沿速度方向"拖尾"，产生运动模糊效果。这通过在采样时随机选择
// 时间点来实现，不同采样看到物体在运动轨迹上的不同位置。
float3 TracePathWithObjectMotionBlur(float3 rayOrigin, float3 rayDir, float motion_time, inout uint seed) {
    const int MAX_BOUNCES = 8;
    const float MAX_THROUGHPUT = 100.0;
    RayPayload payload;
    float3 radiance = float3(0,0,0);
    float3 throughput = float3(1,1,1);
    
    float intensity = camera_info.motion_blur_intensity;
    
    for (int bounce = 0; bounce < MAX_BOUNCES; ++bounce) {
        payload.hit = false;
        payload.material_idx = 0;
        payload.hit_pos = float3(0,0,0);
        payload.normal = float3(0,1,0);
        
        TraceRaySimple(rayOrigin, rayDir, 0.001, 10000.0, payload);
        
        if (!payload.hit) {
            // 使用环境贴图或程序化天空
            float3 rayDirNorm = normalize(rayDir);
            float3 sky;
            if (skybox_info.has_environment_map > 0.5) {
                sky = SampleEnvironmentMap(rayDirNorm);
            } else {
                sky = GetProceduralSky(rayDirNorm);
            }
            radiance += throughput * sky;
            break;
        }
        
        Material mat = materials[payload.material_idx];
        float3 N = normalize(payload.normal);
        float3 V = normalize(-rayDir);
        float2 uv = payload.uv;
        
        bool entering = dot(N, V) > 0.0;
        if (!entering && mat.transmission < 0.01) N = -N;

        float3 hitPos = payload.hit_pos;
        
        // ===== 物体运动模糊：在第一次弹射时应用 =====
        // 检测运动物体并应用模糊效果
        bool is_moving_object = false;
        float3 velocity = float3(0, 0, 0);
        
        if (bounce == 0) {
            uint entity_id = payload.material_idx;
            velocity = GetEntityVelocity(entity_id);
            float vel_length = length(velocity);
            
            if (vel_length > 0.001) {
                is_moving_object = true;
                
                // 时间偏移：motion_time 在 [0,1]，映射到 [-0.5, 0.5]
                // intensity 控制模糊的强度
                float time_offset = (motion_time - 0.5) * intensity;
                
                // 偏移击中点用于光照计算
                // 这会让光照在速度方向上产生变化
                float3 position_offset = velocity * time_offset;
                hitPos = hitPos + position_offset;
            }
        }
        
        float3 baseColor = GetMaterialBaseColor(mat, uv);
        
        // ===== 直接光照计算 (Direct Lighting / NEE) =====
        bool useNEE = true; // 开启直接光照采样
        
        if (useNEE) {
            // 1. 点光源循环
            // 关键修复：对点光源计算时的throughput做特殊处理，防止异常放大
            // 当throughput已经很大时，限制其对点光源贡献的影响
            float3 effectiveThroughput = throughput;
            float maxThroughput = max(max(throughput.r, throughput.g), throughput.b);
            const float MAX_THROUGHPUT_FOR_LIGHT = 50.0; // 点光源计算时的throughput上限，更严格
            if (maxThroughput > MAX_THROUGHPUT_FOR_LIGHT) {
                float scale = MAX_THROUGHPUT_FOR_LIGHT / maxThroughput;
                effectiveThroughput *= scale;
            }
            
            const int MAX_POINT_LIGHTS = 16;
            for(int i=0; i<MAX_POINT_LIGHTS; ++i) {
                PointLight pl = point_lights[i];
                if(pl.strength > 0.0) {
                    float3 pointLightContrib = ComputePointLightContribution(hitPos, N, V, mat, uv, pl, seed);
                    // 使用限制后的effectiveThroughput，而不是原始的throughput
                    radiance += effectiveThroughput * pointLightContrib;
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
            
            // 关键修复：限制throughput的最大值，防止累积导致数值爆炸
            // 当throughput过大时，说明路径已经不稳定，应该提前终止
            float maxThroughput = max(max(throughput.r, throughput.g), throughput.b);
            if (maxThroughput > MAX_THROUGHPUT) {
                // 如果throughput过大，终止路径（避免异常亮点）
                break;
            }
        }

        // 俄罗斯轮盘赌 (Russian Roulette) 终止路径
        // 改进：使用更智能的生存概率计算，避免过度放大throughput
        if (bounce > 2) {
            float maxThroughput = max(max(throughput.r, throughput.g), throughput.b);
            // 改进：使用更大的最小生存概率，避免过度放大throughput
            // 当throughput已经很大时，应该更倾向于终止路径
            float survivalProb = clamp(maxThroughput, 0.3, 0.95); // 提高最小值从0.1到0.3
            
            if (Rand01(seed) > survivalProb) {
                break; // 终止路径
            }
            throughput /= survivalProb; // 无偏估计
            
            // 再次检查throughput是否过大（俄罗斯轮盘赌后可能放大）
            maxThroughput = max(max(throughput.r, throughput.g), throughput.b);
            if (maxThroughput > MAX_THROUGHPUT) {
                break; // 终止路径
            }
        }
        
        // 额外的安全检查：如果throughput过小，提前终止
        if (max(max(throughput.r, throughput.g), throughput.b) < 0.001) {
            break;
        }
    }
    
    return radiance;
}

// 标准路径追踪入口函数
float3 TracePath(float3 rayOrigin, float3 rayDir, inout uint seed) {
    // 不启用物体运动模糊时，使用默认时间 0.5（无偏移）
    return TracePathWithObjectMotionBlur(rayOrigin, rayDir, 0.5, seed);
}

// ==================== 物体运动模糊的屏幕空间实现 ====================
// 
// 正确的运动模糊原理：
// 物体在快门时间内从位置 A 移动到位置 B。我们需要模拟的是：
// 在不同时间点 t，物体位于不同的位置，光线可能击中或错过物体。
//
// 由于我们不能真正移动加速结构中的几何体，我们使用**反向思维**：
// 不移动物体，而是"假装"光线来自物体运动的反方向。
// 
// 如果物体向右移动 velocity = (2, 0, 0)，那么在时间 t=0 时物体在左边，
// t=1 时物体在右边。我们通过将光线起点向速度的**反方向**偏移来模拟这一点：
// 偏移后的光线相当于从"物体曾经在的位置"发出，从而产生边缘模糊。

float3 TracePathObjectMotionBlur(float3 rayOrigin, float3 rayDir, inout uint seed) {
    float intensity = camera_info.motion_blur_intensity;
    
    // 采样随机时间点 [0, 1]
    float motion_time = SampleTime(seed);
    float time_offset = (motion_time - 0.5) * 2.0; // 映射到 [-1, 1]
    
    // ===== 关键改进：反向偏移光线起点 =====
    // 遍历所有可能的运动物体，找到最大速度用于光线偏移
    // 这样可以让光线在边缘区域"看到"运动物体的拖尾
    
    // 首先：追踪原始光线找到击中点
    RayPayload originalPayload;
    originalPayload.hit = false;
    originalPayload.material_idx = 0;
    
    RayDesc originalRay;
    originalRay.Origin = rayOrigin;
    originalRay.Direction = rayDir;
    originalRay.TMin = 0.001;
    originalRay.TMax = 10000.0;
    TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, originalRay, originalPayload);
    
    // 计算用于偏移的速度向量
    // 策略：如果原始光线击中了运动物体，使用该物体的速度
    //       否则，尝试用偏移光线来"捕捉"可能的运动物体
    float3 offset_velocity = float3(0, 0, 0);
    bool original_hit_moving = false;
    
    if (originalPayload.hit) {
        uint entity_id = originalPayload.material_idx;
        float3 vel = GetEntityVelocity(entity_id);
        if (length(vel) > 0.001) {
            offset_velocity = vel;
            original_hit_moving = true;
        }
    }
    
    // ===== 核心运动模糊逻辑 =====
    // 对于运动物体，我们需要：
    // 1. 如果原始光线击中运动物体 -> 根据时间偏移，光线可能"错过"物体（产生拖尾）
    // 2. 如果原始光线没有击中运动物体 -> 根据时间偏移，光线可能"击中"物体（产生前导模糊）
    
    if (original_hit_moving) {
        // 原始光线击中了运动物体
        // 偏移光线起点（反方向），模拟物体在时间 t 的位置
        float3 ray_offset = -offset_velocity * time_offset * intensity;
        float3 adjusted_origin = rayOrigin + ray_offset;
        
        RayPayload adjustedPayload;
        adjustedPayload.hit = false;
        adjustedPayload.material_idx = 0;
        
        RayDesc adjustedRay;
        adjustedRay.Origin = adjusted_origin;
        adjustedRay.Direction = rayDir;
        adjustedRay.TMin = 0.001;
        adjustedRay.TMax = 10000.0;
        TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, adjustedRay, adjustedPayload);
        
        if (adjustedPayload.hit && adjustedPayload.material_idx == originalPayload.material_idx) {
            // 偏移后仍然击中同一运动物体 -> 渲染该物体
            return TracePathWithObjectMotionBlur(adjusted_origin, rayDir, motion_time, seed);
        } else {
            // 偏移后没有击中运动物体 -> 这是边缘区域，渲染背景
            // 这就产生了运动模糊的"拖尾"效果！
            if (adjustedPayload.hit) {
                // 击中了其他物体
                return TracePathWithObjectMotionBlur(adjusted_origin, rayDir, motion_time, seed);
            } else {
                // 没有击中任何物体，返回环境贴图或天空色
                float3 skyDir = normalize(rayDir);
                float3 sky;
                if (skybox_info.has_environment_map > 0.5) {
                    sky = SampleEnvironmentMap(skyDir);
                } else {
                    sky = GetProceduralSky(skyDir);
                }
                return sky;
            }
        }
    } else {
        // 原始光线没有击中运动物体
        // 尝试用偏移光线来"捕捉"可能的运动物体（前导模糊）
        
        // 遍历已知的运动物体，尝试不同的偏移
        // 简化实现：使用多个预定义的偏移方向进行采样
        const int NUM_VELOCITY_PROBES = 4;
        float3 probe_velocities[NUM_VELOCITY_PROBES];
        
        // 从速度缓冲区采样一些已知的运动物体速度
        for (int i = 0; i < NUM_VELOCITY_PROBES; i++) {
            probe_velocities[i] = GetEntityVelocity(i);
        }
        
        // 尝试每个速度方向的偏移
        for (int i = 0; i < NUM_VELOCITY_PROBES; i++) {
            float3 vel = probe_velocities[i];
            if (length(vel) < 0.001) continue;
            
            // 反方向偏移
            float3 ray_offset = -vel * time_offset * intensity;
            float3 adjusted_origin = rayOrigin + ray_offset;
            
            RayPayload probePayload;
            probePayload.hit = false;
            probePayload.material_idx = 0;
            
            RayDesc probeRay;
            probeRay.Origin = adjusted_origin;
            probeRay.Direction = rayDir;
            probeRay.TMin = 0.001;
            probeRay.TMax = 10000.0;
            TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, probeRay, probePayload);
            
            // 如果偏移后击中了对应的运动物体
            if (probePayload.hit) {
                float3 hit_vel = GetEntityVelocity(probePayload.material_idx);
                if (length(hit_vel) > 0.001) {
                    // 找到了运动物体！渲染它（产生前导模糊）
                    return TracePathWithObjectMotionBlur(adjusted_origin, rayDir, motion_time, seed);
                }
            }
        }
        
        // 没有找到任何运动物体，使用原始路径追踪
        return TracePath(rayOrigin, rayDir, seed);
    }
}

// ==================== 物体运动模糊文档 ====================
// 
// 当前实现的局限性：
// 1. 只对第一次击中的物体应用运动模糊检测
// 2. 通过反射/折射看到的运动物体不会有模糊效果
// 3. 极高速度可能导致视觉伪影
//
// 改进方向（未来工作）：
// 1. 支持加速结构的运动几何体（需要引擎支持）
// 2. 在所有弹射中检测运动物体
// 3. 使用更复杂的时间采样策略（如分层采样）

#endif // RAYTRACING_HLSL

