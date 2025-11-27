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

// 光线与AABB相交检测（使用slab方法，最基础实现，严格处理边界）
// 返回true表示相交，false表示不相交
// 如果相交，tHit返回相交的t值（进入AABB的点，如果起点在AABB内则返回tMin）
bool RayAABBIntersect(float3 rayOrigin, float3 rayDir, float3 aabbMin, float3 aabbMax, float tMin, float tMax, out float tHit) {
    const float epsilon = 1e-7;
    
    // 首先严格检查光线起点是否在AABB内（这是关键！）
    bool originInside = (rayOrigin.x >= aabbMin.x - epsilon) && (rayOrigin.x <= aabbMax.x + epsilon) &&
                         (rayOrigin.y >= aabbMin.y - epsilon) && (rayOrigin.y <= aabbMax.y + epsilon) &&
                         (rayOrigin.z >= aabbMin.z - epsilon) && (rayOrigin.z <= aabbMax.z + epsilon);
    
    // 如果起点在AABB内，直接返回相交（使用tMin作为起始点）
    if (originInside) {
        tHit = tMin;
        // tMin应该在有效范围内（由调用者保证），直接返回true
        return true;
    }
    
    // 起点在AABB外，使用标准的slab方法
    // 计算每个轴的相交区间
    float3 t0 = float3(0, 0, 0);
    float3 t1 = float3(0, 0, 0);
    
    // X轴
    if (abs(rayDir.x) < epsilon) {
        // 光线与X轴平行
        if (rayOrigin.x < aabbMin.x - epsilon || rayOrigin.x > aabbMax.x + epsilon) {
            return false;  // 不相交
        }
        t0.x = -1e30;
        t1.x = 1e30;
    } else {
        float invDirX = 1.0 / rayDir.x;
        t0.x = (aabbMin.x - rayOrigin.x) * invDirX;
        t1.x = (aabbMax.x - rayOrigin.x) * invDirX;
        if (t0.x > t1.x) {
            float temp = t0.x;
            t0.x = t1.x;
            t1.x = temp;
        }
    }
    
    // Y轴
    if (abs(rayDir.y) < epsilon) {
        // 光线与Y轴平行
        if (rayOrigin.y < aabbMin.y - epsilon || rayOrigin.y > aabbMax.y + epsilon) {
            return false;  // 不相交
        }
        t0.y = -1e30;
        t1.y = 1e30;
    } else {
        float invDirY = 1.0 / rayDir.y;
        t0.y = (aabbMin.y - rayOrigin.y) * invDirY;
        t1.y = (aabbMax.y - rayOrigin.y) * invDirY;
        if (t0.y > t1.y) {
            float temp = t0.y;
            t0.y = t1.y;
            t1.y = temp;
        }
    }
    
    // Z轴
    if (abs(rayDir.z) < epsilon) {
        // 光线与Z轴平行
        if (rayOrigin.z < aabbMin.z - epsilon || rayOrigin.z > aabbMax.z + epsilon) {
            return false;  // 不相交
        }
        t0.z = -1e30;
        t1.z = 1e30;
    } else {
        float invDirZ = 1.0 / rayDir.z;
        t0.z = (aabbMin.z - rayOrigin.z) * invDirZ;
        t1.z = (aabbMax.z - rayOrigin.z) * invDirZ;
        if (t0.z > t1.z) {
            float temp = t0.z;
            t0.z = t1.z;
            t1.z = temp;
        }
    }
    
    // 找到最大的tNear和最小的tFar
    float tNearMax = max(max(t0.x, t0.y), t0.z);
    float tFarMin = min(min(t1.x, t1.y), t1.z);
    
    // 检查是否相交：tNearMax <= tFarMin
    if (tNearMax > tFarMin + epsilon) {
        return false;  // 不相交
    }
    
    // 检查相交点是否在有效范围内
    // tNearMax是进入AABB的点
    if (tNearMax > tMax + epsilon) {
        return false;  // 进入点在有效范围之外
    }
    
    if (tFarMin < tMin - epsilon) {
        return false;  // AABB完全在光线起点之前
    }
    
    // 确定相交的t值
    if (tNearMax < tMin - epsilon) {
        // 如果进入点在tMin之前，但AABB与光线相交，说明起点在AABB内（但我们已经检查过了）
        // 这种情况不应该发生，但为了安全起见，使用tMin
        tHit = tMin;
    } else {
        // 使用进入点
        tHit = tNearMax;
    }
    
    // 最终检查：确保tHit在有效范围内
    if (tHit < tMin - epsilon || tHit > tMax + epsilon) {
        return false;
    }
    
    return true;
}

// KDT遍历函数：从根节点出发，找到所有相交的叶子节点，合并mask后执行一次TraceRay
// 返回是否命中
bool TraceRayWithKDT(float3 rayOrigin, float3 rayDir, float tMin, float tMax, inout RayPayload payload) {
    // 如果KDT节点数组为空，回退到普通TraceRay
    uint numNodes = kdt_info.num_nodes;
    if (numNodes == 0) {
        RayDesc ray;
        ray.Origin = rayOrigin;
        ray.Direction = rayDir;
        ray.TMin = tMin;
        ray.TMax = tMax;
        TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);
        return payload.hit;
    }
    
    // 第一步：遍历树，找到所有相交的叶子节点，合并mask
    uint mergedMask = 0;
    
    // 使用栈模拟递归遍历（从根节点开始）
    int stack[32];
    int stackTop = 0;
    stack[stackTop++] = 0;  // 根节点索引为0
    
    while (stackTop > 0 && stackTop < 32) {
        int nodeIdx = stack[--stackTop];
        if (nodeIdx < 0 || nodeIdx >= (int)numNodes) {
            continue;
        }
        
        KDTNode node = kdt_nodes[nodeIdx];
        
        // 检查光线是否与当前节点AABB相交
        float tHitAABB;
        bool intersects = RayAABBIntersect(rayOrigin, rayDir, node.aabb_min, node.aabb_max, tMin, tMax, tHitAABB);
        if (!intersects) {
            continue;  // 不相交，跳过
        }
        
        // 如果是叶子节点，合并mask
        if (node.split_axis == -1) {
            mergedMask |= node.mask;
        } else {
            // 内部节点：递归检查左右子节点
            if (node.left_child_idx >= 0) {
                stack[stackTop++] = node.left_child_idx;
            }
            if (node.right_child_idx >= 0) {
                stack[stackTop++] = node.right_child_idx;
            }
        }
    }
    
    // 第二步：如果没有任何相交的叶子节点，返回未命中
    if (mergedMask == 0) {
        payload.hit = false;
        return false;
    }
    
    // 第三步：使用合并后的mask执行一次TraceRay
    RayDesc ray;
    ray.Origin = rayOrigin;
    ray.Direction = rayDir;
    ray.TMin = tMin;
    ray.TMax = tMax;
    
    payload.hit = false;
    TraceRay(as, RAY_FLAG_NONE, mergedMask, 0, 1, 0, ray, payload);
    
    return payload.hit;
}

// 执行路径追踪
float3 TracePath(float3 rayOrigin, float3 rayDir, inout uint seed) {
    const int MAX_BOUNCES = 8; // 优化：8次弹射足够，平衡质量和性能
    const float MAX_THROUGHPUT = 1000.0; // 合理的throughput上限值，防止累积导致数值爆炸
    RayPayload payload;
    float3 radiance = float3(0,0,0);
    float3 throughput = float3(1,1,1);
    
    for (int bounce = 0; bounce < MAX_BOUNCES; ++bounce) {
        // 初始化 payload
        payload.hit = false;
        payload.material_idx = 0;
        payload.hit_pos = float3(0,0,0);
        payload.normal = float3(0,1,0);
        
        // 使用KDT加速的光线追踪
        TraceRayWithKDT(rayOrigin, rayDir, 0.001, 10000.0, payload);
        
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

#endif // RAYTRACING_HLSL

