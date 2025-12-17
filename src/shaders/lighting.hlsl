// ==================== Lighting Functions ====================
// 光源计算相关函数

#ifndef LIGHTING_HLSL
#define LIGHTING_HLSL

#include "common.hlsl"
#include "bsdf.hlsl"
#include "rng.hlsl"

//Volumetric Alpha Shadow: 加上之前没有雾气阴影边缘是硬的，现在有散射阴影边缘是软的柔和的。


// 采样体积密度（统一使用 volumetric_info，支持环境雾和发光光柱）
// 返回总体积密度值（0-1），用于阴影追踪中的透射率计算
float SampleVolumeDensity(float3 pos) {
    if (volumetric_info.enable < 0.5) {
        return 0.0; // 体积渲染未启用
    }
    
    float totalDensity = 0.0;
    
    // 采样环境雾密度
    if (volumetric_info.environment_fog.enable > 0.5) {
        float height = pos.y;
        float top_height = volumetric_info.environment_fog.top_height;
        float bottom_height = volumetric_info.environment_fog.bottom_height;
        
        if (height < top_height) {
            float fogDensity = 0.0;
            if (height <= bottom_height) {
                fogDensity = 1.0;
            } else {
                float normalizedHeight = (height - bottom_height) / (top_height - bottom_height);
                fogDensity = 1.0 - normalizedHeight;
            }
            totalDensity += fogDensity * volumetric_info.environment_fog.density_multiplier;
        }
    }
    
    // 采样发光光柱密度（仅密度，不包括发光）
    if (volumetric_info.light_beam.enable > 0.5) {
        const int MAX_POINT_LIGHTS = 16;
        for (int i = 0; i < MAX_POINT_LIGHTS; ++i) {
            PointLight pl = point_lights[i];
            if (pl.strength <= 0.0) continue;
            
            float3 lightVec = pos - pl.position;
            float distToLight = length(lightVec);
            
            float beamRadius = volumetric_info.light_beam.radius;
            float beamLength = volumetric_info.light_beam.length;
            
            if (distToLight > beamLength) continue;
            
            float3 lightDir = normalize(volumetric_info.light_beam.beam_direction);
            float alongBeam = dot(lightVec, lightDir);
            
            if (alongBeam < 0.0 || alongBeam > beamLength) continue;
            
            float3 projected = alongBeam * lightDir;
            float3 perpendicular = lightVec - projected;
            float radialDist = length(perpendicular);
            
            if (radialDist > beamRadius) continue;
            
            float radialFalloff = 1.0 - saturate(radialDist / beamRadius);
            radialFalloff = pow(radialFalloff, volumetric_info.light_beam.radial_falloff_power);
            
            float longitudinalFalloff = 1.0 - saturate(alongBeam / beamLength);
            longitudinalFalloff = pow(longitudinalFalloff, volumetric_info.light_beam.longitudinal_falloff_power);
            
            float beamDensity = volumetric_info.light_beam.density * radialFalloff * longitudinalFalloff;
            totalDensity = max(totalDensity, beamDensity);
        }
    }
    
    return totalDensity;
}

// Alpha shadow 阴影射线追踪（非递归版本，返回 RGB 可见度，支持有色透射 Beer–Lambert 衰减）
// 返回值：float3(1,1,1) = 完全可见，float3(0,0,0) = 完全遮挡，其他为按通道衰减后的可见度
// 支持透明材质的多重弹射，计算光源到表面的可见度
// 新增：支持体积介质的阴影（Volumetric Alpha Shadow）
float3 TraceAlphaShadowRGB(float3 rayOrigin, float3 rayDirection, float maxDistance, inout uint seed) {
	float3 visibility = float3(1.0, 1.0, 1.0);
	float travelDistance = 0.0;
	const int MAX_BOUNCES = MAX_SHADOW_BOUNCES; // 允许更多透明体穿过次数以捕获混合效果

	for (int i = 0; i < MAX_BOUNCES; ++i) {
		if (travelDistance >= maxDistance || max(max(visibility.r, visibility.g), visibility.b) < MIN_VISIBILITY) {
			break;
		}

		RayDesc shadowRay;
		shadowRay.Origin = rayOrigin;
		shadowRay.Direction = normalize(rayDirection);
		shadowRay.TMin = RAY_TMIN;
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
		if (volumetric_info.enable > 0.5) {
			float3 currentPos = rayOrigin;
			float remainingDist = distanceToHit;
			float volumeStepSize = max(volumetric_info.min_step_size, 0.05f); // 确保最小步长不会太小
			
			int volumeSteps = 0;
			const int MAX_VOLUME_STEPS = 50; // 阴影射线的最大步数限制（防止GPU超时）
			
			while (remainingDist > volumeStepSize && volumeSteps < MAX_VOLUME_STEPS) {
				// 采样当前位置的体积密度
				float density = SampleVolumeDensity(currentPos);
				
				if (density > MIN_DENSITY_THRESHOLD) {
					// 计算体积衰减（Beer-Lambert定律）
					// 基础消光系数（散射+吸收）
					float3 baseExtinction = volumetric_info.scattering.scattering_coeff + volumetric_info.scattering.absorption_coeff;
					
					// 应用密度和环境雾的吸收颜色调制
					// 注意：absorption_color 作为颜色调制，不是直接乘到系数上
					float3 extinction = baseExtinction * density;
					
					// 如果启用环境雾，使用环境雾的吸收颜色来调制消光
					if (volumetric_info.environment_fog.enable > 0.5) {
						// 降低环境雾对阴影的影响，避免过度变暗
						extinction = extinction * lerp(float3(1, 1, 1), volumetric_info.environment_fog.absorption_color, 0.3);
					}
					
					// 应用透射率：exp(-extinction * distance)
					float3 transmittance = exp(-extinction * volumeStepSize);
					visibility *= transmittance;
					
					// 提前终止检查
					if (max(max(visibility.r, visibility.g), visibility.b) < MIN_VISIBILITY) {
						return visibility;
					}
				}
				
				// 移动到下一个采样点
				currentPos += shadowRay.Direction * volumeStepSize;
				remainingDist -= volumeStepSize;
				volumeSteps++;
			}
			
			// 处理最后一段距离（如果还有剩余且未超过步数限制）
			if (remainingDist > MIN_DISTANCE_THRESHOLD && volumeSteps < MAX_VOLUME_STEPS) {
				float density = SampleVolumeDensity(currentPos);
				if (density > MIN_DENSITY_THRESHOLD) {
					float3 baseExtinction = volumetric_info.scattering.scattering_coeff + volumetric_info.scattering.absorption_coeff;
					float3 extinction = baseExtinction * density;
					if (volumetric_info.environment_fog.enable > 0.5) {
						extinction = extinction * lerp(float3(1, 1, 1), volumetric_info.environment_fog.absorption_color, 0.3);
					}
					float3 transmittance = exp(-extinction * remainingDist);
					visibility *= transmittance;
				}
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
		if (mat.transmission > TRANSMISSION_THRESHOLD) {
			// 使用 transmission_color 作为每单位距离的透射色近似：visibility *= transmission_color ^ distance
			// 并额外乘以传输强度标量
			float3 colorAttenuation = pow(mat.transmission_color, distanceToHit);
			visibility *= colorAttenuation * mat.transmission;

			// 继续追踪，向前偏移起点以避免自相交
			rayOrigin = shadowPayload.hit_pos + normalize(rayDirection) * RAY_EPSILON;
			continue;
		}

		// 检查 alpha 贴图（如果材质有透明度贴图）
		if (mat.has_alpha_map > ALPHA_MAP_THRESHOLD) {
			// 使用亮度作为 alpha 的近似，按亮度决定通道级别的透射
			float colorBrightness = dot(mat.base_color, RGB_LUMINANCE_WEIGHTS);
			float alpha = colorBrightness;

			if (alpha < mat.alpha_threshold) {
				float factor = alpha / mat.alpha_threshold;
				visibility *= float3(factor, factor, factor);
				rayOrigin = shadowPayload.hit_pos + normalize(rayDirection) * RAY_EPSILON;
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

// 计算面光源的直接光照贡献（使用 Principled BSDF，支持 MIS）
float3 ComputeAreaLightContribution(float3 hitPos, float3 normal, float3 viewDir, Material material, float2 uv, AreaLight light, inout uint seed) {
    float3 totalContribution = float3(0, 0, 0);
    
    for (int sample_idx = 0; sample_idx < NUM_AREA_LIGHT_SAMPLES; ++sample_idx) {
        // 1. 在光源表面上随机采样一个点
        float u_base = Rand01(seed) - 0.5;
        float v_base = Rand01(seed) - 0.5;
        
        float3 samplePos = light.position + (light.u_axis * u_base * light.width) + (light.v_axis * v_base * light.height);
        
        // 2. 几何计算：计算从击中点到光源采样点的方向和距离
        float3 lightVec = samplePos - hitPos;
        float distSq = dot(lightVec, lightVec);
        float dist = sqrt(distSq);
        float3 lightDir = normalize(lightVec);
        
        float NdotL = dot(normal, lightDir);
        float3 lightNormal = light.direction;
        float LdotLn = dot(-lightDir, lightNormal);
        
        // 检查光源是否在表面正面，以及采样点是否在光源正面
        if (NdotL <= 0.0 || LdotLn <= 0.0) {
            continue;
        }
        
        // ===== 卡通渲染：应用阶梯光照 =====
        if (camera_info.enable_toon_shading > 0) {
            int steps = max(2, camera_info.toon_shading_steps);
            NdotL = StepShading(NdotL, steps);
        }
        
        // 3. 阴影检测：计算光源到表面的可见度
        float3 visibility = TraceAlphaShadowRGB(hitPos + normal * RAY_EPSILON, lightDir, dist - RAY_EPSILON, seed);
        
        if (max(max(visibility.r, visibility.g), visibility.b) < MIN_VISIBILITY_CUTOFF) {
            continue; // 完全被遮挡，跳过此采样
        }
        
        // 4. 计算光源采样的概率密度函数（PDF）
        float area = light.width * light.height;
        float pdf_light = distSq / (area * LdotLn + EPSILON_DIVIDE_ZERO);
        
        // 5. 光源的辐射度（自发光）
        float3 Le = light.color * light.strength;
        
        // 6. 使用 Principled BSDF 评估材质响应
        float pdf_brdf;
        float3 brdf_eval = EvaluatePrincipledBSDF(material, viewDir, lightDir, normal, uv, pdf_brdf);
        
        // 7. MIS权重：平衡光源采样和BSDF采样
        float w_light = BalanceHeuristic(pdf_light, pdf_brdf);
        
        // 8. 计算最终的光照贡献
        float geometryFactor = (NdotL * LdotLn * area) / (distSq + EPSILON_DIVIDE_ZERO);
        float3 contribution = Le * brdf_eval * visibility * w_light / (pdf_light + EPSILON_DIVIDE_ZERO);
        
        totalContribution += contribution;
    }
    
    return totalContribution / float(NUM_AREA_LIGHT_SAMPLES);
}

// 计算点光源的直接光照贡献（使用 Principled BSDF）
float3 ComputePointLightContribution(float3 hitPos, float3 normal, float3 viewDir, Material material, float2 uv, PointLight light, inout uint seed) {
	// 计算从击中点到光源的方向和距离
	float3 lightVec = light.position - hitPos;
	float lightDistance = length(lightVec);
	float3 lightDir = normalize(lightVec);
	
	// 改进的距离保护：使用更大的最小距离，并考虑光源半径
	// 确保光源半径不为0或过小
	float effectiveRadius = max(light.radius, MIN_LIGHT_RADIUS);
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
	attenuation = min(attenuation, MAX_ATTENUATION);
	
	// 检查光源是否在表面的正面（背面光照不贡献）
	float NdotL = dot(normal, lightDir);
	if (NdotL <= 0.0) {
		return float3(0.0, 0.0, 0.0);
	}
	
	// ===== 卡通渲染：应用阶梯光照 =====
	// 将平滑的 NdotL 转换为阶梯式（如果启用）
	if (camera_info.enable_toon_shading > 0) {
		int steps = max(2, camera_info.toon_shading_steps);
		NdotL = StepShading(NdotL, steps);
	}
	
	// 检查阴影遮挡：计算光源到表面的可见度
	float3 shadowOrigin = hitPos + normal * RAY_EPSILON; // 偏移起点以避免自相交
	// 修正阴影射线距离：起点已偏移RAY_EPSILON，距离应该相应减少
	float shadowRayDistance = max(safeDistance - RAY_EPSILON, 0.0);
	float3 lightVisibility = TraceAlphaShadowRGB(shadowOrigin, lightDir, shadowRayDistance, seed);
	
	if (max(max(lightVisibility.r, lightVisibility.g), lightVisibility.b) < MIN_VISIBILITY_CUTOFF) {
		return float3(0.0, 0.0, 0.0); // 完全被遮挡
	}
	
	// 使用 Principled BSDF 评估材质响应
	float pdf_brdf;
	float3 brdf_eval = EvaluatePrincipledBSDF(material, viewDir, lightDir, normal, uv, pdf_brdf);
	
	// 计算最终的光照贡献
	float3 radiance = brdf_eval * light.color * attenuation * lightVisibility * SHADOW_DEBUG_BOOST;
	
	// 添加radiance上限保护，防止异常值导致过曝亮点
	// 限制单个点光源的最大贡献，避免数值爆炸
	radiance = min(radiance, float3(MAX_RADIANCE_PER_LIGHT, MAX_RADIANCE_PER_LIGHT, MAX_RADIANCE_PER_LIGHT));
	
	return radiance;
}

#endif // LIGHTING_HLSL

