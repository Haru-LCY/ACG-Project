// ==================== Lighting Functions ====================
// 光源计算相关函数

#ifndef LIGHTING_HLSL
#define LIGHTING_HLSL

#include "common.hlsl"
#include "bsdf.hlsl"
#include "rng.hlsl"

// Alpha shadow 阴影射线追踪（非递归版本，返回 RGB 可见度，支持有色透射 Beer–Lambert 衰减）
// 返回值：float3(1,1,1) = 完全可见，float3(0,0,0) = 完全遮挡，其他为按通道衰减后的可见度
float3 TraceAlphaShadowRGB(float3 rayOrigin, float3 rayDirection, float maxDistance, inout uint seed) {
	float3 visibility = float3(1.0, 1.0, 1.0);
	float travelDistance = 0.0;
	const int MAX_BOUNCES = 6; // 允许更多透明体穿过次数以捕获混合
	const float MIN_VISIBILITY = 0.001; // 如果可见性过低，提前终止

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

		if (!shadowPayload.hit) {
			// 没有hit = 完全可见
			return visibility;
		}

		// 获取材质信息
		Material mat = materials[shadowPayload.material_idx];
		float distanceToHit = length(shadowPayload.hit_pos - rayOrigin);
		travelDistance += distanceToHit;

		// 如果材质是透明的，应用有色透射（Beer–Lambert 简化）并继续追踪
		if (mat.transmission > 0.01) {
			// 使用 transmission_color 作为每单位距离的透射色近似：visibility *= transmission_color ^ distance
			// 并额外乘以传输强度 scalar
			float3 colorAttenuation = pow(mat.transmission_color, distanceToHit);
			visibility *= colorAttenuation * mat.transmission;

			// 继续追踪，向前偏移
			rayOrigin = shadowPayload.hit_pos + normalize(rayDirection) * 0.001;
			continue;
		}

		// 检查 alpha 贴图
		if (mat.has_alpha_map > 0.5) {
			// 原先用亮度作为 alpha 的近似，这里也按亮度决定通道级别的透射
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

		// 不透明的物体，完全遮挡
		return float3(0.0, 0.0, 0.0);
	}

	return visibility;
}

// 计算面光源贡献 (使用 Principled BSDF)
float3 ComputeAreaLightContribution(float3 hitPos, float3 normal, float3 viewDir, Material material, float2 uv, AreaLight light, inout uint seed) {
    const int NUM_LIGHT_SAMPLES = 1;
    float3 totalContribution = float3(0, 0, 0);
    
    for (int sample_idx = 0; sample_idx < NUM_LIGHT_SAMPLES; ++sample_idx) {
        // 1. 随机采样光源表面
        float u_base = Rand01(seed) - 0.5;
        float v_base = Rand01(seed) - 0.5;
        
        float3 samplePos = light.position + (light.u_axis * u_base * light.width) + (light.v_axis * v_base * light.height);
        
        // 2. 几何计算
        float3 lightVec = samplePos - hitPos;
        float distSq = dot(lightVec, lightVec);
        float dist = sqrt(distSq);
        float3 lightDir = normalize(lightVec);
        
        float NdotL = dot(normal, lightDir);
        float3 lightNormal = light.direction;
        float LdotLn = dot(-lightDir, lightNormal);
        
        if (NdotL <= 0.0 || LdotLn <= 0.0) {
            continue;
        }
        
        // 3. 阴影检测
        const float RAY_EPSILON = 0.001;
        float3 visibility = TraceAlphaShadowRGB(hitPos + normal * RAY_EPSILON, lightDir, dist - RAY_EPSILON, seed);
        
        if (max(max(visibility.r, visibility.g), visibility.b) < 0.001) {
            continue;
        }
        
        // 4. 计算光源采样PDF
        float area = light.width * light.height;
        float pdf_light = distSq / (area * LdotLn + 1e-8);
        
        // 5. 辐射度
        float3 Le = light.color * light.strength;
        
        // 6. 使用 Principled BSDF 评估
        float pdf_brdf;
        float3 brdf_eval = EvaluatePrincipledBSDF(material, viewDir, lightDir, normal, uv, pdf_brdf);
        
        // 7. MIS权重
        float w_light = BalanceHeuristic(pdf_light, pdf_brdf);
        
        // 8. 最终贡献
        float geometryFactor = (NdotL * LdotLn * area) / (distSq + 1e-8);
        float3 contribution = Le * brdf_eval * visibility * w_light / (pdf_light + 1e-8);
        
        totalContribution += contribution;
    }
    
    return totalContribution / float(NUM_LIGHT_SAMPLES);
}

// 计算点光源的直接光照贡献 (使用 Principled BSDF)
float3 ComputePointLightContribution(float3 hitPos, float3 normal, float3 viewDir, Material material, float2 uv, PointLight light, inout uint seed) {
	// 计算光源方向和距离
	float3 lightVec = light.position - hitPos;
	float lightDistance = length(lightVec);
	float3 lightDir = normalize(lightVec);
	
	// 计算光照衰减（平方反比定律）
	float attenuation = light.strength / (4.0 * PI * lightDistance * lightDistance);
	
	// 检查光源是否在表面的正面
	float NdotL = dot(normal, lightDir);
	if (NdotL <= 0.0) {
		return float3(0.0, 0.0, 0.0);
	}
	
	// 检查阴影遮挡
	const float RAY_EPSILON = 0.001;
	float3 shadowOrigin = hitPos + normal * RAY_EPSILON;
	float3 lightVisibility = TraceAlphaShadowRGB(shadowOrigin, lightDir, lightDistance, seed);
	
	if (max(max(lightVisibility.r, lightVisibility.g), lightVisibility.b) < 0.001) {
		return float3(0.0, 0.0, 0.0);
	}
	
	// 使用 Principled BSDF 评估
	float pdf_brdf;
	float3 brdf_eval = EvaluatePrincipledBSDF(material, viewDir, lightDir, normal, uv, pdf_brdf);
	
	// 最终光照
	float3 radiance = brdf_eval * light.color * attenuation * lightVisibility * SHADOW_DEBUG_BOOST;
	
	return radiance;
}

#endif // LIGHTING_HLSL

