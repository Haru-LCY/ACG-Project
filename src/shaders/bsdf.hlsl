// ==================== BSDF Implementation ====================
// Principled BSDF 相关函数实现

#ifndef BSDF_HLSL
#define BSDF_HLSL

#include "common.hlsl"
#include "rng.hlsl"

// MIS 的 Power heuristic（β=2），用于多重重要性采样权重计算
float PowerHeuristic(float pdf_a, float pdf_b) {
    float a = pdf_a * pdf_a;
    float b = pdf_b * pdf_b;
    return a / (a + b + 1e-8);
}

// MIS 的 Balance heuristic，用于多重重要性采样权重计算
float BalanceHeuristic(float pdf_a, float pdf_b) {
    return pdf_a / (pdf_a + pdf_b + 1e-8);
}

// Lambertian 漫反射采样
float3 SampleCosineHemisphere(float3 n, inout uint seed, out float pdf) {
	float u1 = Rand01(seed);
	float u2 = Rand01(seed);
	float r = sqrt(u1);
	float theta = 2.0 * PI * u2;
	float x = r * cos(theta);
	float y = r * sin(theta);
	float z = sqrt(max(0.0, 1.0 - u1));
	
	float3 up = abs(n.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
	float3 t = normalize(cross(up, n));
	float3 b = cross(n, t);
	
	float3 dir = normalize(x * t + y * b + z * n);
	pdf = z / PI; // 余弦加权的概率密度函数
	return dir;
}

// 获取材质的基础颜色（考虑纹理）
float3 GetMaterialBaseColor(Material mat, float2 uv) {
    if (mat.texture_id >= 0 && mat.texture_id < MAX_TEXTURES) {
        // 有纹理，采样纹理颜色
        float4 texColor = textures[mat.texture_id].SampleLevel(texSampler, uv, 0);
        return texColor.rgb;
    } else {
        // 无纹理，使用材质颜色
        return mat.base_color;
    }
}

// Schlick Fresnel 近似，计算菲涅尔反射系数
float3 FresnelSchlick(float cosTheta, float3 F0) {
	return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// Snell's Law 折射计算
// 返回折射光线方向，如果发生全反射则返回 float3(0,0,0)
bool Refract(float3 I, float3 N, float eta, out float3 refracted) {
	float cosi = dot(-I, N);
	float cost2 = 1.0 - eta * eta * (1.0 - cosi * cosi);
	if (cost2 < 0.0) {
		// 全反射
		refracted = float3(0, 0, 0);
		return false;
	}
	refracted = eta * I + (eta * cosi - sqrt(cost2)) * N;
	return true;
}

// 介质Fresnel（用于透明材质）
float FresnelDielectric(float cosThetaI, float etaI, float etaT) {
	cosThetaI = clamp(cosThetaI, -1.0, 1.0);
	bool entering = cosThetaI > 0.0;
	if (!entering) {
		float temp = etaI;
		etaI = etaT;
		etaT = temp;
		cosThetaI = abs(cosThetaI);
	}
	
	float sinThetaI = sqrt(max(0.0, 1.0 - cosThetaI * cosThetaI));
	float sinThetaT = etaI / etaT * sinThetaI;
	
	if (sinThetaT >= 1.0) {
		return 1.0; // 全反射
	}
	
	float cosThetaT = sqrt(max(0.0, 1.0 - sinThetaT * sinThetaT));
	
	float rParallel = ((etaT * cosThetaI) - (etaI * cosThetaT)) / 
	                  ((etaT * cosThetaI) + (etaI * cosThetaT));
	float rPerpendicular = ((etaI * cosThetaI) - (etaT * cosThetaT)) / 
	                       ((etaI * cosThetaI) + (etaT * cosThetaT));
	
	return (rParallel * rParallel + rPerpendicular * rPerpendicular) / 2.0;
}

// ==================== Principled BSDF Implementation ====================

// 从法线构建正交基（切线和副切线），用于各向异性BSDF
void BuildOrthonormalBasis(float3 N, out float3 T, out float3 B) {
	float3 up = abs(N.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
	T = normalize(cross(up, N));
	B = cross(N, T);
}

// 计算各向异性 alpha 值（减少重复计算）
void ComputeAnisotropicAlpha(float roughness, float anisotropic, out float alpha_x, out float alpha_y) {
	float aspect = sqrt(1.0 - anisotropic * 0.9);
	alpha_x = roughness * roughness / aspect;
	alpha_y = roughness * roughness * aspect;
}

// 计算镜面反射颜色和 F0（减少重复计算）
void ComputeSpecularColor(Material mat, float3 baseColor, out float3 spec_color, out float3 F0) {
	float lum = dot(baseColor, float3(0.299, 0.587, 0.114));
	float3 tint_color = lum > 0 ? baseColor / lum : float3(1, 1, 1);
	spec_color = lerp(float3(1, 1, 1), tint_color, mat.specular_tint);
	F0 = lerp(0.08 * mat.specular * spec_color, baseColor, mat.metallic);
}

// 计算 lobe 权重（减少重复计算）
void ComputeLobeWeights(float3 F, float3 kD, float clearcoat, 
                         out float diffuse_weight, out float specular_weight, out float clearcoat_weight) {
	diffuse_weight = max(max(kD.x, kD.y), kD.z);
	specular_weight = max(max(F.x, F.y), F.z);
	clearcoat_weight = clearcoat * 0.25;
	
	float total_weight = diffuse_weight + specular_weight + clearcoat_weight + 1e-7;
	diffuse_weight /= total_weight;
	specular_weight /= total_weight;
	clearcoat_weight /= total_weight;
}

// GGX 微表面法线分布函数（支持各向异性）
float GGX_D(float3 H, float3 N, float3 T, float3 B, float roughness, float anisotropic) {
	float alpha_x, alpha_y;
	ComputeAnisotropicAlpha(roughness, anisotropic, alpha_x, alpha_y);
	
	float NdotH = max(dot(N, H), 0.0); // 确保点积非负
	float TdotH = dot(T, H);
	float BdotH = dot(B, H);
	
	float a2 = alpha_x * alpha_y;
	float3 v = float3(alpha_y * TdotH, alpha_x * BdotH, a2 * NdotH);
	float v2 = dot(v, v);
	
	// 数值稳定性保护：防止v2过小导致w2爆炸
	// 当v2非常小时，D项应该接近0，而不是无限大
	const float MIN_V2 = 1e-10; // 防止除零的最小值
	v2 = max(v2, MIN_V2);
	
	float w2 = a2 / v2;
	
	// 限制w2的最大值，防止数值爆炸
	// 理论上D项的最大值约为 1/(PI * alpha^2)，这里使用更保守的上限
	const float MAX_W2 = 1e6; // 合理的上限值，防止数值溢出
	w2 = min(w2, MAX_W2);
	
	float D = a2 * w2 * w2 / PI;
	
	// 最终安全检查：限制D项的最大值
	const float MAX_D = 1e4; // 防止异常大的D值导致数值问题
	return min(D, MAX_D);
}

// GGX 几何项（Smith G1），计算自遮挡
float GGX_G1(float3 V, float3 N, float3 T, float3 B, float roughness, float anisotropic) {
	float alpha_x, alpha_y;
	ComputeAnisotropicAlpha(roughness, anisotropic, alpha_x, alpha_y);
	
	float NdotV = abs(dot(N, V));
	float TdotV = dot(T, V);
	float BdotV = dot(B, V);
	
	float a2 = alpha_x * alpha_x * TdotV * TdotV + alpha_y * alpha_y * BdotV * BdotV;
	float lambda = (-1.0 + sqrt(1.0 + a2 / (NdotV * NdotV))) * 0.5;
	return 1.0 / (1.0 + lambda);
}

float GGX_G(float3 V, float3 L, float3 N, float3 T, float3 B, float roughness, float anisotropic) {
	return GGX_G1(V, N, T, B, roughness, anisotropic) * GGX_G1(L, N, T, B, roughness, anisotropic);
}

// GGX 分布采样（各向异性）- 内部版本，接受预计算的切空间基向量 T, B
float3 SampleGGX_Internal(float3 N, float3 V, float3 T, float3 B, float roughness, float anisotropic, 
                          float anisotropic_rotation, inout uint seed, out float pdf) {
	float u1 = Rand01(seed);
	float u2 = Rand01(seed);
	
	// 应用各向异性旋转
	float rotation_angle = anisotropic_rotation * 2.0 * PI;
	float cos_rot = cos(rotation_angle);
	float sin_rot = sin(rotation_angle);
	float3 T_rot = cos_rot * T + sin_rot * B;
	float3 B_rot = -sin_rot * T + cos_rot * B;
	T = T_rot;
	B = B_rot;
	
	// 使用各向异性参数进行采样
	float alpha_x, alpha_y;
	ComputeAnisotropicAlpha(roughness, anisotropic, alpha_x, alpha_y);
	
	float phi = atan2(alpha_y * sin(2.0 * PI * u2), alpha_x * cos(2.0 * PI * u2));
	float cos_phi = cos(phi);
	float sin_phi = sin(phi);
	
	float alpha_p = sqrt(cos_phi * cos_phi * alpha_x * alpha_x + sin_phi * sin_phi * alpha_y * alpha_y);
	float tan_theta = alpha_p * sqrt(u1 / (1.0 - u1 + 1e-7));
	float cos_theta = 1.0 / sqrt(1.0 + tan_theta * tan_theta);
	float sin_theta = tan_theta * cos_theta;
	
	// 局部空间中的半向量
	float3 H_local = float3(sin_theta * cos_phi, sin_theta * sin_phi, cos_theta);
	float3 H = normalize(T * H_local.x + B * H_local.y + N * H_local.z);
	
	// 反射得到光线方向
	float3 L = reflect(-V, H);
	
	// 计算概率密度函数
	float D = GGX_D(H, N, T, B, roughness, anisotropic);
	float NdotH = max(dot(N, H), 0.0);
	float VdotH = max(dot(V, H), 0.0);
	pdf = D * NdotH / (4.0 * VdotH + 1e-7);
	
	return L;
}

// GGX 分布采样（各向异性）- 外部接口，保持向后兼容性
float3 SampleGGX(float3 N, float3 V, float roughness, float anisotropic, float anisotropic_rotation, 
                 inout uint seed, out float pdf) {
	float3 T, B;
	BuildOrthonormalBasis(N, T, B);
	return SampleGGX_Internal(N, V, T, B, roughness, anisotropic, anisotropic_rotation, seed, pdf);
}

// Sheen BRDF 评估（Estevez & Kulla 模型），用于织物的绒毛效果
float3 EvaluateSheen(float3 V, float3 L, float3 N, float3 base_color, float sheen, float sheen_tint) {
	if (sheen < 1e-5) return float3(0, 0, 0);
	
	float3 H = normalize(V + L);
	float VdotH = max(dot(V, H), 0.0);
	
	// Sheen 颜色计算
	float lum = dot(base_color, float3(0.299, 0.587, 0.114));
	float3 tint_color = lum > 0 ? base_color / lum : float3(1, 1, 1);
	float3 sheen_color = lerp(float3(1, 1, 1), tint_color, sheen_tint);
	
	// Sheen 的 Schlick Fresnel 近似
	float fresnel = pow(1.0 - VdotH, 5.0);
	return sheen * sheen_color * fresnel;
}

// Clearcoat BRDF 评估，用于清漆层（如汽车漆）
float3 EvaluateClearcoat(float3 V, float3 L, float3 N, float clearcoat, float clearcoat_roughness, out float pdf) {
	if (clearcoat < 1e-5) {
		pdf = 0.0;
		return float3(0, 0, 0);
	}
	
	float3 H = normalize(V + L);
	float NdotH = max(dot(N, H), 0.0);
	float NdotL = max(dot(N, L), 0.0);
	float NdotV = max(dot(N, V), 0.0);
	float VdotH = max(dot(V, H), 0.0);
	
	// Clearcoat 使用固定的折射率 IOR = 1.5
	float F0 = 0.04; // ((1.5 - 1) / (1.5 + 1))^2
	float F = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
	
	// Clearcoat 的 GGX 分布
	float alpha = clearcoat_roughness * clearcoat_roughness;
	float alpha2 = alpha * alpha;
	float denom = NdotH * NdotH * (alpha2 - 1.0) + 1.0;
	float D = alpha2 / (PI * denom * denom + 1e-7);
	
	// 几何项（Clearcoat 的简化版本）
	float k = alpha / 2.0;
	float G_V = NdotV / (NdotV * (1.0 - k) + k);
	float G_L = NdotL / (NdotL * (1.0 - k) + k);
	float G = G_V * G_L;
	
	pdf = D * NdotH / (4.0 * VdotH + 1e-7);
	
	float clearcoat_value = clearcoat * 0.25 * F * D * G / (4.0 * NdotV * NdotL + 1e-7);
	return float3(clearcoat_value, clearcoat_value, clearcoat_value);
}

// Clearcoat lobe 采样，生成清漆层反射方向
float3 SampleClearcoat(float3 N, float3 V, float clearcoat_roughness, inout uint seed, out float pdf) {
	float u1 = Rand01(seed);
	float u2 = Rand01(seed);
	
	// Clearcoat 的 GGX 采样
	float alpha = clearcoat_roughness * clearcoat_roughness;
	float alpha2 = alpha * alpha;
	
	float cos_theta = sqrt((1.0 - u1) / (u1 * (alpha2 - 1.0) + 1.0));
	float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
	float phi = 2.0 * PI * u2;
	
	// 构建切空间基
	float3 T, B;
	BuildOrthonormalBasis(N, T, B);
	
	// 半向量
	float3 H = normalize(sin_theta * cos(phi) * T + sin_theta * sin(phi) * B + cos_theta * N);
	
	// 反射得到光线方向
	float3 L = reflect(-V, H);
	
	// 计算概率密度函数
	float NdotH = max(dot(N, H), 0.0);
	float VdotH = max(dot(V, H), 0.0);
	float D = alpha2 / (PI * pow(NdotH * NdotH * (alpha2 - 1.0) + 1.0, 2.0) + 1e-7);
	pdf = D * NdotH / (4.0 * VdotH + 1e-7);
	
	return L;
}

// Principled BSDF 评估，计算给定入射和出射方向的BRDF值
float3 EvaluatePrincipledBSDF(Material mat, float3 V, float3 L, float3 N, float2 uv, out float pdf) {
	float3 baseColor = GetMaterialBaseColor(mat, uv);
	
	float NdotL = dot(N, L);
	float NdotV = dot(N, V);
	
	if (NdotL <= 0.0 || NdotV <= 0.0) {
		pdf = 0.0;
		return float3(0, 0, 0);
	}
	
	float3 H = normalize(V + L);
	float NdotH = max(dot(N, H), 0.0);
	float VdotH = max(dot(V, H), 0.0);
	
	// 构建切空间基（用于各向异性）
	float3 T, B;
	BuildOrthonormalBasis(N, T, B);
	
	// 计算镜面反射颜色
	float3 spec_color, F0;
	ComputeSpecularColor(mat, baseColor, spec_color, F0);
	
	// 菲涅尔项
	float3 F = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
	
	// GGX 镜面反射项
	float D = GGX_D(H, N, T, B, mat.roughness, mat.anisotropic);
	float G = GGX_G(V, L, N, T, B, mat.roughness, mat.anisotropic);
	
	// 改进的除零保护：使用更大的epsilon，并限制分母的最小值
	const float MIN_DENOM = 1e-5; // 更大的最小值保护
	float denominator = max(4.0 * NdotV * NdotL, MIN_DENOM);
	float3 specular = D * F * G / denominator;
	
	// 限制镜面反射项的最大值，防止数值爆炸
	// 即使D、F、G都很大，specular也不应该超过合理范围
	const float MAX_SPECULAR = 1e3; // 合理的上限值
	specular = min(specular, float3(MAX_SPECULAR, MAX_SPECULAR, MAX_SPECULAR));
	
	// 漫反射项（能量守恒）
	float3 kD = (1.0 - F) * (1.0 - mat.metallic);
	float3 diffuse = kD * baseColor / PI;
	
	// Sheen 项
	float3 sheen = EvaluateSheen(V, L, N, baseColor, mat.sheen, mat.sheen_tint);
	
	// Clearcoat 项
	float clearcoat_pdf;
	float3 clearcoat = EvaluateClearcoat(V, L, N, mat.clearcoat, mat.clearcoat_roughness, clearcoat_pdf);
	
	// 组合所有 lobe
	float3 brdf = diffuse + specular + sheen + clearcoat;
	
	// 计算组合的概率密度函数
	float diffuse_weight, specular_weight, clearcoat_weight;
	ComputeLobeWeights(F, kD, mat.clearcoat, diffuse_weight, specular_weight, clearcoat_weight);
	
	float pdf_diffuse = NdotL / PI;
	float pdf_specular = D * NdotH / (4.0 * VdotH + 1e-7);
	
	pdf = diffuse_weight * pdf_diffuse + specular_weight * pdf_specular + clearcoat_weight * clearcoat_pdf;
	
	return brdf * NdotL;
}

// Principled BSDF 采样（重要性采样），生成新的光线方向
float3 SamplePrincipledBSDF(Material mat, float3 V, float3 N, float2 uv, inout uint seed, out float pdf, out float3 weight) {
	float3 baseColor = GetMaterialBaseColor(mat, uv);
	
	// 构建切空间基（预计算，避免在采样函数中重复计算）
	float3 T, B;
	BuildOrthonormalBasis(N, T, B);
	
	// 计算各 lobe 的权重
	float VdotH_approx = max(dot(V, N), 0.0);
	
	float3 spec_color, F0;
	ComputeSpecularColor(mat, baseColor, spec_color, F0);
	float3 F_approx = F0 + (1.0 - F0) * pow(1.0 - VdotH_approx, 5.0);
	
	float3 kD = (1.0 - F_approx) * (1.0 - mat.metallic);
	
	float diffuse_weight, specular_weight, clearcoat_weight;
	ComputeLobeWeights(F_approx, kD, mat.clearcoat, diffuse_weight, specular_weight, clearcoat_weight);
	
	// 根据权重选择要采样的 lobe
	float lobe_choice = Rand01(seed);
	float3 L;
	
	if (lobe_choice < diffuse_weight) {
		// 采样漫反射 lobe
		L = SampleCosineHemisphere(N, seed, pdf);
		weight = float3(1, 1, 1); // 将在BRDF评估时乘以实际值
	} else if (lobe_choice < diffuse_weight + specular_weight) {
		// 采样镜面反射 lobe（使用预计算的切空间基 T, B）
		L = SampleGGX_Internal(N, V, T, B, mat.roughness, mat.anisotropic, mat.anisotropic_rotation, seed, pdf);
		weight = float3(1, 1, 1);
	} else {
		// 采样 clearcoat lobe
		L = SampleClearcoat(N, V, mat.clearcoat_roughness, seed, pdf);
		weight = float3(1, 1, 1);
	}
	
	// 评估完整的BSDF以获得实际权重
	float eval_pdf;
	float3 brdf = EvaluatePrincipledBSDF(mat, V, L, N, uv, eval_pdf);
	
	// 更新PDF为组合的PDF
	pdf = eval_pdf;
	
	// 权重 = BRDF * NdotL / PDF（但BRDF已经包含了NdotL）
	// 关键修复：限制weight的最大值，防止pdf过小时weight爆炸
	if (pdf > 1e-7) {
		weight = brdf / pdf;
		
		// 限制weight的最大值，防止数值爆炸
		// 理论上weight应该接近1，但在某些极端情况下（如低粗糙度镜面反射）可能很大
		// 这里使用更严格的上限，防止单个采样导致异常亮点
		const float MAX_WEIGHT = 50.0; // 降低上限值，更严格地防止weight爆炸
		float maxWeight = max(max(weight.r, weight.g), weight.b);
		if (maxWeight > MAX_WEIGHT) {
			float scale = MAX_WEIGHT / maxWeight;
			weight *= scale;
		}
	} else {
		weight = float3(0, 0, 0);
	}
	
	return L;
}

#endif // BSDF_HLSL

