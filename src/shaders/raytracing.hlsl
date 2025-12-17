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

// ACES 色调映射（解决过曝/刺眼问题的关键，将HDR值映射到LDR范围）
float3 ACESFilm(float3 x) {
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// ==================== Homogeneous Volume Rendering ====================
// Homogeneous Volume Rendering 基础设施
// 支持体积发光（Volumetric Emission）和单次散射（Single Scattering）

// 简单的噪声函数（用于烟雾密度变化）
float Noise3D(float3 p) {
    // 简单的哈希噪声
    float3 i = floor(p);
    float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f); // smoothstep
    
    float n = i.x + i.y * 57.0 + 113.0 * i.z;
    return frac(sin(n) * 43758.5453);
}

// 采样环境雾密度（基于高度的程序化雾）
float SampleEnvironmentFogDensity(float3 pos) {
    if (volumetric_info.environment_fog.enable < 0.5) {
        return 0.0; // 环境雾未启用
    }
    
    float height = pos.y;
    float top_height = volumetric_info.environment_fog.top_height;
    float bottom_height = volumetric_info.environment_fog.bottom_height;
    
    // 在顶部高度以上无雾
    if (height >= top_height) {
        return 0.0;
    }
    
    // 在底部高度以下雾密度最大
    if (height <= bottom_height) {
        return volumetric_info.environment_fog.density_multiplier;
    }
    
    // 线性插值：高度越低密度越高
    float normalizedHeight = (height - bottom_height) / (top_height - bottom_height);
    float fogDensity = 1.0 - normalizedHeight; // 底部=1.0，顶部=0.0
    return fogDensity * volumetric_info.environment_fog.density_multiplier;
}

// 采样发光光柱的密度和发光（从点光源发出的体积光柱）
// 返回: (density, emission_r, emission_g, emission_b)
float4 SampleLightBeamProperties(float3 pos) {
    if (volumetric_info.light_beam.enable < 0.5) {
        return float4(0, 0, 0, 0); // 光柱未启用
    }
    
    const int MAX_POINT_LIGHTS = 16;
    float maxDensity = 0.0;
    float3 totalEmission = float3(0, 0, 0);
    
    // 遍历所有点光源，创建体积光柱效果
    for (int i = 0; i < MAX_POINT_LIGHTS; ++i) {
        PointLight pl = point_lights[i];
        if (pl.strength <= 0.0) continue;
        
        // 计算从光源到采样点的向量
        float3 lightVec = pos - pl.position;
        float distToLight = length(lightVec);
        
        // 使用配置参数
        float beamRadius = volumetric_info.light_beam.radius;
        float beamLength = volumetric_info.light_beam.length;
        float baseDensity = volumetric_info.light_beam.density;
        float emissionIntensity = volumetric_info.light_beam.emission_intensity;
        
        // 检查是否在光柱长度范围内
        if (distToLight > beamLength) continue;
        
        // 计算光柱方向（使用配置的方向，默认向下）
        float3 lightDir = normalize(volumetric_info.light_beam.beam_direction);
        float3 toPos = lightVec;
        
        // 计算沿光柱方向的投影距离
        float alongBeam = dot(toPos, lightDir);
        
        // 只考虑光柱方向的正面（如果向下，则只考虑光源下方）
        if (alongBeam < 0.0) continue;
        if (alongBeam > beamLength) continue;
        
        // 计算垂直于光柱方向的横向距离
        float3 projected = alongBeam * lightDir;
        float3 perpendicular = toPos - projected;
        float radialDist = length(perpendicular);
        
        // 如果横向距离超过半径，跳过
        if (radialDist > beamRadius) continue;
        
        // 计算径向衰减（距离中心越远，密度越小）
        float radialFalloff = 1.0 - saturate(radialDist / beamRadius);
        radialFalloff = pow(radialFalloff, volumetric_info.light_beam.radial_falloff_power);
        
        // 计算纵向衰减（距离光源越远，密度越小）
        float longitudinalFalloff = 1.0 - saturate(alongBeam / beamLength);
        longitudinalFalloff = pow(longitudinalFalloff, volumetric_info.light_beam.longitudinal_falloff_power);
        
        // 计算密度（结合径向和纵向衰减）
        float density = baseDensity * radialFalloff * longitudinalFalloff;
        
        // 发光颜色：混合配置的颜色和光源颜色
        float3 emissionColor = volumetric_info.light_beam.emission_color * pl.color;
        float3 emission = emissionColor * emissionIntensity * density;
        
        // 累积密度和发光（取最大值，避免过度叠加）
        if (density > maxDensity) {
            maxDensity = density;
            totalEmission = emission;
        } else if (density > 0.1) {
            // 如果多个光源重叠，混合发光颜色
            float blendFactor = density / (maxDensity + density + 0.001);
            totalEmission = lerp(totalEmission, emission, blendFactor);
            maxDensity = max(maxDensity, density * 0.8);
        }
    }
    
    if (maxDensity > 0.001) {
        return float4(maxDensity, totalEmission);
    }
    
    return float4(0, 0, 0, 0); // 无光柱
}

// 采样体积属性（合并环境雾和发光光柱）
// 返回: (density, emission_r, emission_g, emission_b)
float4 SampleVolumeProperties(float3 pos) {
    // 采样环境雾密度
    float envFogDensity = SampleEnvironmentFogDensity(pos);
    
    // 采样发光光柱
    float4 beamProps = SampleLightBeamProperties(pos);
    float beamDensity = beamProps.x;
    float3 beamEmission = beamProps.yzw;
    
    // 合并密度（取最大值或叠加，这里使用最大值避免过度累积）
    float totalDensity = max(envFogDensity, beamDensity);
    
    // 发光只来自光柱
    float3 totalEmission = beamEmission;
    
    return float4(totalDensity, totalEmission);
}

// Henyey-Greenstein 相位函数（用于前向/后向散射）
// g: 各向异性参数 (-1 到 1)，g>0 前向散射，g<0 后向散射，g=0 各向同性
float PhaseFunctionHG(float cosTheta, float g) {
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * cosTheta;
    return (1.0 - g2) / (4.0 * PI * pow(max(denom, 0.0001), 1.5));
}

// 计算单次散射贡献（从光源到采样点的散射）
float3 ComputeSingleScattering(float3 pos, float3 viewDir, float density, inout uint seed) {
    if (volumetric_info.scattering.enable < 0.5) {
        return float3(0, 0, 0); // 散射未启用
    }
    
    float3 scatteringCoeff = volumetric_info.scattering.scattering_coeff;
    float phaseG = volumetric_info.scattering.phase_g;
    
    float3 scattering = float3(0, 0, 0);
    
    // 采样所有点光源
    const int MAX_POINT_LIGHTS = 16;
    for (int i = 0; i < MAX_POINT_LIGHTS; ++i) {
        PointLight pl = point_lights[i];
        if (pl.strength <= 0.0) continue;
        
        // 计算从采样点到光源的方向
        float3 lightVec = pl.position - pos;
        float lightDist = length(lightVec);
        float3 lightDir = normalize(lightVec);
        
        // 计算相位函数（viewDir 和 lightDir 之间的角度）
        float cosTheta = dot(viewDir, lightDir);
        float phase = PhaseFunctionHG(cosTheta, phaseG);
        
        // 计算光源到采样点的可见度（考虑体积衰减）
        float3 shadowOrigin = pos + lightDir * 0.01; // 稍微偏移避免自相交
        float shadowDist = max(lightDist - 0.01, 0.0);
        float3 visibility = TraceAlphaShadowRGB(shadowOrigin, lightDir, shadowDist, seed);
        
        // 计算光源衰减
        float distSq = lightDist * lightDist;
        float attenuation = pl.strength / (4.0 * PI * distSq);
        
        // 单次散射贡献 = 散射系数 * 相位函数 * 光源辐射 * 可见度 * 衰减
        float3 lightRadiance = pl.color * attenuation * visibility;
        scattering += scatteringCoeff * phase * lightRadiance * density;
    }
    
    // 采样所有面光源
    const int MAX_AREA_LIGHTS = 8;
    for (int j = 0; j < MAX_AREA_LIGHTS; ++j) {
        AreaLight al = area_lights[j];
        if (al.strength <= 0.0) continue;
        
        // 简化：使用面光源中心点
        float3 lightVec = al.position - pos;
        float lightDist = length(lightVec);
        float3 lightDir = normalize(lightVec);
        
        // 检查光源是否在正面
        float LdotLn = dot(-lightDir, al.direction);
        if (LdotLn <= 0.0) continue;
        
        // 相位函数
        float cosTheta = dot(viewDir, lightDir);
        float phase = PhaseFunctionHG(cosTheta, phaseG);
        
        // 可见度
        float3 shadowOrigin = pos + lightDir * 0.01;
        float shadowDist = max(lightDist - 0.01, 0.0);
        float3 visibility = TraceAlphaShadowRGB(shadowOrigin, lightDir, shadowDist, seed);
        
        // 面光源衰减（简化计算）
        float distSq = lightDist * lightDist;
        float area = al.width * al.height;
        float attenuation = al.strength / (4.0 * PI * distSq);
        
        float3 lightRadiance = al.color * attenuation * visibility;
        scattering += scatteringCoeff * phase * lightRadiance * density;
    }
    
    return scattering;
}

// 体积积分结果结构体
struct VolumeIntegrationResult {
    float3 radiance;      // 体积发光贡献（emission + single scattering）
    float3 transmittance; // 体积透射率
};

// 沿光线积分体积贡献（完整实现：体积发光 + 单次散射）
// 优化：使用自适应步长，在低密度区域使用大步长以提高性能
VolumeIntegrationResult IntegrateVolumeAlongRay(float3 rayOrigin, float3 rayDir, float maxDist, float3 throughput, inout uint seed) {
    // 检查是否启用体积渲染
    if (volumetric_info.enable < 0.5) {
        VolumeIntegrationResult result;
        result.radiance = float3(0, 0, 0);
        result.transmittance = float3(1, 1, 1);
        return result;
    }
    
    // 使用配置参数
    float minStepSize = volumetric_info.min_step_size;
    float maxStepSize = volumetric_info.max_step_size;
    const float DENSITY_THRESHOLD_LOW = 0.1;   // 低密度阈值
    const float DENSITY_THRESHOLD_HIGH = 0.3;  // 高密度阈值
    float3 scatteringCoeff = volumetric_info.scattering.scattering_coeff;
    float3 absorptionCoeff = volumetric_info.scattering.absorption_coeff;
    
    VolumeIntegrationResult result;
    result.radiance = float3(0, 0, 0);
    result.transmittance = float3(1, 1, 1); // 透射率
    
    float dist = 0.0;
    int steps = 0;
    const int MAX_STEPS = 100; // 最大步数（降低以提高性能）
    
    // 预采样第一个点以确定初始步长
    float3 pos = rayOrigin;
    float4 volProps = SampleVolumeProperties(pos);
    float prevDensity = volProps.x;
    float currentStepSize = prevDensity > DENSITY_THRESHOLD_HIGH ? minStepSize : 
                           (prevDensity < DENSITY_THRESHOLD_LOW ? maxStepSize : 
                           lerp(minStepSize, maxStepSize, (DENSITY_THRESHOLD_HIGH - prevDensity) / (DENSITY_THRESHOLD_HIGH - DENSITY_THRESHOLD_LOW)));
    
    while (dist < maxDist && steps < MAX_STEPS) {
        pos = rayOrigin + rayDir * dist;
        volProps = SampleVolumeProperties(pos);
        float density = volProps.x;
        float3 emission = volProps.yzw;
        
        // 自适应步长：根据密度动态调整
        // 高密度区域使用小步长，低密度区域使用大步长
        float stepSize = currentStepSize;
        if (density > DENSITY_THRESHOLD_HIGH) {
            stepSize = minStepSize; // 高密度：小步长
        } else if (density < DENSITY_THRESHOLD_LOW) {
            stepSize = maxStepSize; // 低密度：大步长
        } else {
            // 中等密度：线性插值
            float t = (DENSITY_THRESHOLD_HIGH - density) / (DENSITY_THRESHOLD_HIGH - DENSITY_THRESHOLD_LOW);
            stepSize = lerp(minStepSize, maxStepSize, t);
        }
        
        // 确保不超过剩余距离
        stepSize = min(stepSize, maxDist - dist);
        if (stepSize < 0.001) break; // 距离太小时退出
        
        if (density > 0.001) {
            // 计算体积衰减（Beer-Lambert 定律）
            float3 extinction = scatteringCoeff + absorptionCoeff;
            float3 stepTransmittance = exp(-extinction * density * stepSize);
            
            // 1. 累积体积发光（Volumetric Emission）
            result.radiance += throughput * result.transmittance * emission * stepSize;
            
            // 2. 累积单次散射（Single Scattering）
            // 优化：在环境雾模式下降低散射采样频率以提高性能
            if (volumetric_info.scattering.enable > 0.5) {
                // 每N步才计算一次散射，减少计算量
                bool shouldComputeScattering = (steps % 3 == 0) || (density > 0.5); // 高密度区域或每3步
                if (shouldComputeScattering) {
                    float3 singleScattering = ComputeSingleScattering(pos, rayDir, density, seed);
                    result.radiance += throughput * result.transmittance * singleScattering * stepSize;
                }
            }
            
            // 更新透射率
            result.transmittance *= stepTransmittance;
            
            // 提前终止：如果透射率太低，贡献可忽略
            float maxTrans = max(max(result.transmittance.r, result.transmittance.g), result.transmittance.b);
            if (maxTrans < 0.001) break;
        }
        
        dist += stepSize;
        currentStepSize = stepSize; // 保存当前步长用于下一次迭代
        steps++;
    }
    
    return result;
}

// 简单的光线追踪函数，直接使用硬件加速的 TraceRay API
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
    const int MAX_BOUNCES = MAX_PATH_BOUNCES;
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
        
        // ===== 体积渲染：在击中表面前采样体积 =====
        // 先追踪光线找到最近的表面
        TraceRaySimple(rayOrigin, rayDir, 0.001, 10000.0, payload);
        
        // 计算到表面的距离
        float distToSurface = payload.hit ? length(payload.hit_pos - rayOrigin) : 10000.0;
        
        // 沿光线积分体积贡献（从起点到表面）
        VolumeIntegrationResult volumeResult = IntegrateVolumeAlongRay(rayOrigin, rayDir, distToSurface, throughput, seed);
        radiance += volumeResult.radiance;
        
        // 应用体积衰减到 throughput
        throughput *= volumeResult.transmittance;
        
        if (!payload.hit) {
            // 光线未击中任何物体，使用环境贴图或程序化天空
            float3 rayDirNorm = normalize(rayDir);
            float3 sky;
            if (skybox_info.has_environment_map > 0.5) {
                sky = SampleEnvironmentMap(rayDirNorm);
            } else {
                sky = GetProceduralSky(rayDirNorm);
            }
            radiance += throughput * sky; // 累积环境光照贡献
            break; // 终止路径追踪
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
        
        // ===== 直接光照计算 (Direct Lighting / Next Event Estimation) =====
        bool useNEE = true; // 开启直接光照采样（重要性采样光源）
        
        if (useNEE) {
            // 1. 遍历所有点光源并计算直接光照贡献
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
            
            // 2. 遍历所有面光源并计算直接光照贡献
            const int MAX_AREA_LIGHTS = 8; // 假设最多8个面光源
            for (int j = 0; j < MAX_AREA_LIGHTS; ++j) {
                AreaLight al = area_lights[j];
                if (al.strength <= 0.0) continue;
                
                float3 areaLightContrib = ComputeAreaLightContribution(hitPos, N, V, mat, uv, al, seed);
                radiance += throughput * areaLightContrib;
            }
        }

        // ===== 间接光照 (BSDF Sampling / 递归路径追踪) =====
        
        // 添加自发光贡献（如果材质有自发光）
        if (mat.emission_strength > 0.0) {
            radiance += throughput * mat.emission_color * mat.emission_strength;
            break; // 击中发光体，终止路径（发光体不继续弹射）
        }
        
        // [透明材质逻辑：处理折射和反射]
        if (mat.transmission > 0.01) {
            float etaI = 1.0;
            float etaT = mat.ior;
            float3 normal = N;
            if (!entering) {
                etaI = mat.ior; etaT = 1.0; normal = -N;
            }
            
            float cosTheta = abs(dot(normal, V));
            float Fr = FresnelDielectric(cosTheta, etaI, etaT); // 计算菲涅尔反射系数
            
            if (Rand01(seed) < Fr) {
                // 根据菲涅尔系数随机选择反射
                rayDir = reflect(-V, normal);
                rayOrigin = hitPos + normal * 0.001; // 偏移起点以避免自相交
            } else {
                // 折射
                float3 refracted;
                if (Refract(-V, normal, etaI/etaT, refracted)) {
                    rayDir = normalize(refracted);
                    rayOrigin = hitPos - normal * 0.001; // 偏移起点以避免自相交
                    // Beer's Law 吸收（光线在介质中传播时的颜色衰减）
                    if (entering) throughput *= mat.transmission_color;
                } else {
                    rayDir = reflect(-V, normal); // 全反射（当折射角超过临界角时）
                    rayOrigin = hitPos + normal * 0.001;
                }
            }
        } 
        // [不透明材质逻辑 - 使用 Principled BSDF]
        else {
            // 采样 Principled BSDF 生成新的光线方向
            float pdf_sample;
            float3 bsdf_weight;
            rayDir = SamplePrincipledBSDF(mat, V, N, uv, seed, pdf_sample, bsdf_weight);
            
            // 检查采样是否成功
            if (pdf_sample < 1e-7 || dot(N, rayDir) <= 0.0) {
                break; // 无效采样或光线方向在表面下方，终止路径
            }
            
            rayOrigin = hitPos + N * 0.001; // 偏移起点以避免自相交
            throughput *= bsdf_weight; // 累积BSDF权重
            
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
                break; // 随机终止路径（俄罗斯轮盘赌）
            }
            throughput /= survivalProb; // 无偏估计（补偿终止概率）
            
            // 再次检查throughput是否过大（俄罗斯轮盘赌后可能放大）
            maxThroughput = max(max(throughput.r, throughput.g), throughput.b);
            if (maxThroughput > MAX_THROUGHPUT) {
                break; // 终止路径
            }
        }
        
        // 额外的安全检查：如果throughput过小，提前终止（贡献可忽略）
        if (max(max(throughput.r, throughput.g), throughput.b) < 0.001) {
            break;
        }
    }
    
    return radiance;
}

// 标准路径追踪入口函数（不启用物体运动模糊）
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

