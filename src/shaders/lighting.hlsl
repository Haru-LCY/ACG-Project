// ==================== Lighting Functions ====================
// 光源计算相关函数

#ifndef LIGHTING_HLSL
#define LIGHTING_HLSL

#include "common.hlsl"
#include "bsdf.hlsl"
#include "rng.hlsl"

//Volumetric Alpha Shadow: 加上之前没有雾气阴影边缘是硬的，现在有散射阴影边缘是软的柔和的。


// 简单的体积密度采样（程序化，基于高度）
// 返回体积密度值（0-1），0表示无体积介质
// 在此高度以下都有雾
float SampleVolumeDensity(float3 pos) {
    const float TSINGHUA_BOX_TOP = 1.6; 
    float height = pos.y;
    
    // 在盒子高度以下都有雾，密度随高度增加而减少
    if (height >= TSINGHUA_BOX_TOP) {
        return 0.0; // 盒子高度以上无雾
    }
    
    // 使用更明显的密度分布：高度越低，密度越高
    // 在底部（Y=0）密度最大，到盒子顶部（Y=2.98）密度逐渐减少到0
    float normalizedHeight = height / TSINGHUA_BOX_TOP; // 归一化到 [0, 1]
    float fogDensity = 1.0 - normalizedHeight; // 线性衰减：底部1.0，顶部0.0
    return fogDensity * 1.5; // 大幅增加密度到1.5（非常明显）
}

// Alpha shadow 阴影射线追踪（非递归版本，返回 RGB 可见度，支持有色透射 Beer–Lambert 衰减）
// 返回值：float3(1,1,1) = 完全可见，float3(0,0,0) = 完全遮挡，其他为按通道衰减后的可见度
// 支持透明材质的多重弹射，计算光源到表面的可见度
// 新增：支持体积介质的阴影（Volumetric Alpha Shadow）
float3 TraceAlphaShadowRGB(float3 rayOrigin, float3 rayDirection, float maxDistance, inout uint seed) {
	float3 visibility = float3(1.0, 1.0, 1.0);
	float travelDistance = 0.0;
	const int MAX_BOUNCES = MAX_SHADOW_BOUNCES; // 允许更多透明体穿过次数以捕获混合效果
	const float MIN_VISIBILITY = 0.001; // 如果可见性过低，提前终止追踪

	for (int i = 0; i < MAX_BOUNCES; ++i) {
		if (travelDistance >= maxDistance || max(max(visibility.r, visibility.g), visibility.b) < MIN_VISIBILITY) {
			break;
		}

		RayDesc shadowRay;
		shadowRay.Origin = rayOrigin;
		shadowRay.Direction = normalize(rayDirection);
		shadowRay.TMin = 0.0001;
		shadowRay.TMax = maxDistance - travelDistance;

		RayPayload shadowPayload;
		shadowPayload.hit = false;
		shadowPayload.material_idx = 0;
		shadowPayload.hit_pos = float3(0, 0, 0);
		shadowPayload.normal = float3(0, 1, 0);

		// 追踪阴影射线
		TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, shadowRay, shadowPayload);

		// 计算到击中点的距离（如果没有击中，使用最大距离）
		float distanceToHit = shadowPayload.hit ? length(shadowPayload.hit_pos - rayOrigin) : (maxDistance - travelDistance);
		
		// ===== 体积介质采样（在到达表面之前）=====
		// 简单的步进采样：沿射线路径采样体积密度
		const float VOLUME_STEP_SIZE = 0.05; // 大幅减小步长以提高精度和效果
		float3 currentPos = rayOrigin;
		float remainingDist = distanceToHit;
		
		while (remainingDist > VOLUME_STEP_SIZE) {
			// 采样当前位置的体积密度
			float density = SampleVolumeDensity(currentPos);
			
			if (density > 0.001) {
				// 计算体积衰减（Beer-Lambert定律）
				// 大幅增强吸收系数，让雾效果非常明显
				// 使用更强的吸收：每单位距离的衰减系数
				float3 absorption = float3(0.8, 0.8, 1.0) * density; // 大幅增强的蓝色雾（非常明显）
				float extinction = max(max(absorption.r, absorption.g), absorption.b);
				
				// 应用透射率：exp(-extinction * distance)
				float transmittance = exp(-extinction * VOLUME_STEP_SIZE);
				visibility *= transmittance;
				
				// 提前终止检查
				if (max(max(visibility.r, visibility.g), visibility.b) < MIN_VISIBILITY) {
					return visibility;
				}
			}
			
			// 移动到下一个采样点
			currentPos += shadowRay.Direction * VOLUME_STEP_SIZE;
			remainingDist -= VOLUME_STEP_SIZE;
		}
		
		// 处理最后一段距离（如果还有剩余）
		if (remainingDist > 0.001) {
			float density = SampleVolumeDensity(currentPos);
			if (density > 0.001) {
				float3 absorption = float3(0.8, 0.8, 1.0) * density;
				float extinction = max(max(absorption.r, absorption.g), absorption.b);
				float transmittance = exp(-extinction * remainingDist);
				visibility *= transmittance;
			}
		}
		
		if (!shadowPayload.hit) {
			// 没有击中任何物体 = 完全可见
			return visibility;
		}

		// 获取材质信息
		Material mat = materials[shadowPayload.material_idx];
		travelDistance += distanceToHit;

		// 如果材质是透明的，应用有色透射（Beer–Lambert 简化）并继续追踪
		if (mat.transmission > 0.01) {
			// 使用 transmission_color 作为每单位距离的透射色近似：visibility *= transmission_color ^ distance
			// 并额外乘以传输强度标量
			float3 colorAttenuation = pow(mat.transmission_color, distanceToHit);
			visibility *= colorAttenuation * mat.transmission;

			// 继续追踪，向前偏移起点以避免自相交
			rayOrigin = shadowPayload.hit_pos + normalize(rayDirection) * 0.001;
			continue;
		}

		// 检查 alpha 贴图（如果材质有透明度贴图）
		if (mat.has_alpha_map > 0.5) {
			// 使用亮度作为 alpha 的近似，按亮度决定通道级别的透射
			float colorBrightness = dot(mat.base_color, float3(0.299, 0.587, 0.114));
			float alpha = colorBrightness;

			if (alpha < mat.alpha_threshold) {
				float factor = alpha / mat.alpha_threshold;
				visibility *= float3(factor, factor, factor);
				rayOrigin = shadowPayload.hit_pos + normalize(rayDirection) * 0.001;
				continue;
			} else {
				visibility *= float3(alpha, alpha, alpha);
				return visibility;
			}
		}

		// 不透明的物体，完全遮挡光线
		return float3(0.0, 0.0, 0.0);
	}

	return visibility;
}

// 计算面光源的直接光照贡献（使用完整的 MIS：光源采样 + BRDF 采样）
float3 ComputeAreaLightContribution(float3 hitPos, float3 normal, float3 viewDir, Material material, float2 uv, AreaLight light, inout uint seed) {
    float3 totalContribution = float3(0, 0, 0);
    
    // ==================== 策略1: 光源采样 ====================
    // 在光源表面上随机采样一个点
    {
        float u_base = Rand01(seed) - 0.5;
        float v_base = Rand01(seed) - 0.5;
        
        float3 samplePos = light.position + (light.u_axis * u_base * light.width) + (light.v_axis * v_base * light.height);
        
        // 几何计算：计算从击中点到光源采样点的方向和距离
        float3 lightVec = samplePos - hitPos;
        float distSq = dot(lightVec, lightVec);
        float dist = sqrt(distSq);
        float3 lightDir = normalize(lightVec);
        
        float NdotL = dot(normal, lightDir);
        float3 lightNormal = light.direction;
        float LdotLn = dot(-lightDir, lightNormal);
        
        // 检查光源是否在表面正面，以及采样点是否在光源正面
        if (NdotL > 0.0 && LdotLn > 0.0) {
            // 阴影检测：计算光源到表面的可见度
            const float RAY_EPSILON = 0.001;
            float3 visibility = TraceAlphaShadowRGB(hitPos + normal * RAY_EPSILON, lightDir, dist - RAY_EPSILON, seed);
            
            if (max(max(visibility.r, visibility.g), visibility.b) >= 0.001) {
                // 计算光源采样的概率密度函数（PDF）
                float area = light.width * light.height;
                float pdf_light = distSq / (area * LdotLn + 1e-8);
                
                // 光源的辐射度（自发光）
                float3 Le = light.color * light.strength;
                
                // 使用 Principled BSDF 评估材质响应
                float pdf_brdf;
                float3 brdf_eval = EvaluatePrincipledBSDF(material, viewDir, lightDir, normal, uv, pdf_brdf);
                
                // MIS 权重：平衡光源采样和 BRDF 采样
                float w_light = BalanceHeuristic(pdf_light, pdf_brdf);
                
                // 计算光照贡献
                // contribution = Le * brdf_eval * visibility * weight / pdf
                float3 contribution = Le * brdf_eval * visibility * w_light / (pdf_light + 1e-8);
                
                totalContribution += contribution;
            }
        }
    }
    
    // ==================== 策略2: BRDF 采样 ====================
    // 根据 BRDF 的重要性采样方向
    {
        float pdf_brdf;
        float3 brdf_weight;
        
        // 使用 BRDF 重要性采样生成光线方向
        float3 sampledDir = SamplePrincipledBSDF(material, viewDir, normal, uv, seed, pdf_brdf, brdf_weight);
        
        // 检查采样方向是否有效
        float NdotL = dot(normal, sampledDir);
        if (NdotL > 0.0 && pdf_brdf > 1e-8) {
            // 检查光线是否击中光源
            // 计算光线与光源平面的交点
            float3 lightNormal = light.direction;
            float denom = dot(sampledDir, lightNormal);
            
            // 确保光线朝向光源（从表面射向光源的正面）
            if (denom < -1e-6) {
                // 计算光线与光源平面的交点距离
                float3 planeOrigin = light.position;
                float t = dot(planeOrigin - hitPos, lightNormal) / denom;
                
                if (t > 0.0) {
                    // 计算交点位置
                    float3 hitPoint = hitPos + sampledDir * t;
                    
                    // 检查交点是否在矩形光源范围内
                    float3 localPos = hitPoint - light.position;
                    float u_coord = dot(localPos, light.u_axis);
                    float v_coord = dot(localPos, light.v_axis);
                    
                    float halfWidth = light.width * 0.5;
                    float halfHeight = light.height * 0.5;
                    
                    if (abs(u_coord) <= halfWidth && abs(v_coord) <= halfHeight) {
                        // 击中了光源！计算阴影
                        const float RAY_EPSILON = 0.001;
                        float3 visibility = TraceAlphaShadowRGB(hitPos + normal * RAY_EPSILON, sampledDir, t - RAY_EPSILON, seed);
                        
                        if (max(max(visibility.r, visibility.g), visibility.b) >= 0.001) {
                            // 计算光源采样的 PDF（从这个采样点看）
                            float distSq = t * t;
                            float area = light.width * light.height;
                            float LdotLn = -denom; // 已经计算过了
                            float pdf_light = distSq / (area * LdotLn + 1e-8);
                            
                            // 光源的辐射度
                            float3 Le = light.color * light.strength;
                            
                            // MIS 权重：平衡 BRDF 采样和光源采样
                            float w_brdf = BalanceHeuristic(pdf_brdf, pdf_light);
                            
                            // 计算光照贡献
                            // BRDF 采样的贡献 = Le * brdf_weight * visibility * w_brdf
                            // 注意：brdf_weight 已经包含了 BRDF * NdotL / pdf_brdf
                            float3 contribution = Le * brdf_weight * visibility * w_brdf;
                            
                            totalContribution += contribution;
                        }
                    }
                }
            }
        }
    }
    
    return totalContribution;
}

// 计算点光源的直接光照贡献（使用 Principled BSDF）
float3 ComputePointLightContribution(float3 hitPos, float3 normal, float3 viewDir, Material material, float2 uv, PointLight light, inout uint seed) {
	// 计算从击中点到光源的方向和距离
	float3 lightVec = light.position - hitPos;
	float lightDistance = length(lightVec);
	float3 lightDir = normalize(lightVec);
	
	// 改进的距离保护：使用更大的最小距离，并考虑光源半径
	// 如果光源半径太小或为0，使用更安全的最小距离以避免数值问题
	const float MIN_LIGHT_DISTANCE = 0.05; // 增加到0.05，提供更好的数值稳定性保护
	const float MIN_RADIUS = 0.01; // 光源半径的最小值
	
	// 确保光源半径不为0或过小
	float effectiveRadius = max(light.radius, MIN_RADIUS);
	float safeDistance = max(lightDistance, max(effectiveRadius, MIN_LIGHT_DISTANCE));
	
	// 改进的衰减计算：使用平滑衰减曲线，避免硬截止
	// 当距离接近最小距离时，使用平滑过渡以避免数值不稳定
	float distSq = safeDistance * safeDistance;
	float baseAttenuation = light.strength / (4.0 * PI * distSq); // 平方反比定律
	
	// 添加额外的衰减因子，当距离很小时进一步衰减
	// 使用平滑的衰减曲线：1 / (1 + (d_min/d)^2)
	float distanceRatio = MIN_LIGHT_DISTANCE / safeDistance;
	float smoothFactor = 1.0 / (1.0 + distanceRatio * distanceRatio);
	float attenuation = baseAttenuation * smoothFactor;
	
	// 限制衰减的最大值，防止异常大的衰减值导致数值问题
	const float MAX_ATTENUATION = 1e4; // 合理的上限值
	attenuation = min(attenuation, MAX_ATTENUATION);
	
	// 检查光源是否在表面的正面（背面光照不贡献）
	float NdotL = dot(normal, lightDir);
	if (NdotL <= 0.0) {
		return float3(0.0, 0.0, 0.0);
	}
	
	// 检查阴影遮挡：计算光源到表面的可见度
	const float RAY_EPSILON = 0.001;
	float3 shadowOrigin = hitPos + normal * RAY_EPSILON; // 偏移起点以避免自相交
	// 修正阴影射线距离：起点已偏移RAY_EPSILON，距离应该相应减少
	float shadowRayDistance = max(safeDistance - RAY_EPSILON, 0.0);
	float3 lightVisibility = TraceAlphaShadowRGB(shadowOrigin, lightDir, shadowRayDistance, seed);
	
	if (max(max(lightVisibility.r, lightVisibility.g), lightVisibility.b) < 0.001) {
		return float3(0.0, 0.0, 0.0); // 完全被遮挡
	}
	
	// 使用 Principled BSDF 评估材质响应
	float pdf_brdf;
	float3 brdf_eval = EvaluatePrincipledBSDF(material, viewDir, lightDir, normal, uv, pdf_brdf);
	
	// 计算最终的光照贡献
	float3 radiance = brdf_eval * light.color * attenuation * lightVisibility * SHADOW_DEBUG_BOOST;
	
	// 添加radiance上限保护，防止异常值导致过曝亮点
	// 限制单个点光源的最大贡献，避免数值爆炸
	// 由于衰减和BRDF都已经有了上限保护，这里使用更严格的上限值
	const float MAX_RADIANCE_PER_LIGHT = 100.0; // 大幅降低上限值，更严格地防止异常亮点
	radiance = min(radiance, float3(MAX_RADIANCE_PER_LIGHT, MAX_RADIANCE_PER_LIGHT, MAX_RADIANCE_PER_LIGHT));
	
	return radiance;
}

#endif // LIGHTING_HLSL

