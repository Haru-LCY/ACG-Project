// ==================== BSDF Implementation ====================
// Principled BSDF 相关函数实现

#ifndef BSDF_HLSL
#define BSDF_HLSL

#include "common.hlsl"
#include "rng.hlsl"

// Power heuristic for MIS (beta=2)
float PowerHeuristic(float pdf_a, float pdf_b) {
    float a = pdf_a * pdf_a;
    float b = pdf_b * pdf_b;
    return a / (a + b + 1e-8);
}

// Balance heuristic for MIS
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
	pdf = z / PI; // cosine-weighted PDF
	return dir;
}

// 获取材质的基础颜色（考虑纹理）
float3 GetMaterialBaseColor(Material mat, float2 uv) {
    if (mat.texture_id >= 0 && mat.texture_id < 16) {
        // 有纹理，采样纹理颜色
        float4 texColor = textures[mat.texture_id].SampleLevel(texSampler, uv, 0);
        return texColor.rgb;
    } else {
        // 无纹理，使用材质颜色
        return mat.base_color;
    }
}

// Schlick Fresnel
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

// Build orthonormal basis from normal
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

// GGX Distribution (with anisotropic support)
float GGX_D(float3 H, float3 N, float3 T, float3 B, float roughness, float anisotropic) {
	float alpha_x, alpha_y;
	ComputeAnisotropicAlpha(roughness, anisotropic, alpha_x, alpha_y);
	
	float NdotH = max(dot(N, H), 0.0); // 确保非负
	float TdotH = dot(T, H);
	float BdotH = dot(B, H);
	
	float a2 = alpha_x * alpha_y;
	float3 v = float3(alpha_y * TdotH, alpha_x * BdotH, a2 * NdotH);
	float v2 = dot(v, v);
	
	// 添加数值稳定性保护：防止v2过小导致w2爆炸
	// 当v2非常小时，D项应该接近0，而不是无限大
	const float MIN_V2 = 1e-10; // 防止除零的最小值
	v2 = max(v2, MIN_V2);
	
	float w2 = a2 / v2;
	
	// 限制w2的最大值，防止数值爆炸
	// 理论上D项的最大值约为 1/(PI * alpha^2)，这里使用更保守的上限
	const float MAX_W2 = 1e6; // 合理的上限，防止数值溢出
	w2 = min(w2, MAX_W2);
	
	float D = a2 * w2 * w2 / PI;
	
	// 最终安全检查：限制D项的最大值
	const float MAX_D = 1e4; // 防止异常大的D值
	return min(D, MAX_D);
}

// GGX Geometry term (Smith)
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

// Sample GGX distribution (anisotropic) - 内部版本，接受预计算的 T, B
float3 SampleGGX_Internal(float3 N, float3 V, float3 T, float3 B, float roughness, float anisotropic, 
                          float anisotropic_rotation, inout uint seed, out float pdf) {
	float u1 = Rand01(seed);
	float u2 = Rand01(seed);
	
	// Apply anisotropic rotation
	float rotation_angle = anisotropic_rotation * 2.0 * PI;
	float cos_rot = cos(rotation_angle);
	float sin_rot = sin(rotation_angle);
	float3 T_rot = cos_rot * T + sin_rot * B;
	float3 B_rot = -sin_rot * T + cos_rot * B;
	T = T_rot;
	B = B_rot;
	
	// Sample with anisotropy
	float alpha_x, alpha_y;
	ComputeAnisotropicAlpha(roughness, anisotropic, alpha_x, alpha_y);
	
	float phi = atan2(alpha_y * sin(2.0 * PI * u2), alpha_x * cos(2.0 * PI * u2));
	float cos_phi = cos(phi);
	float sin_phi = sin(phi);
	
	float alpha_p = sqrt(cos_phi * cos_phi * alpha_x * alpha_x + sin_phi * sin_phi * alpha_y * alpha_y);
	float tan_theta = alpha_p * sqrt(u1 / (1.0 - u1 + 1e-7));
	float cos_theta = 1.0 / sqrt(1.0 + tan_theta * tan_theta);
	float sin_theta = tan_theta * cos_theta;
	
	// Half vector in local space
	float3 H_local = float3(sin_theta * cos_phi, sin_theta * sin_phi, cos_theta);
	float3 H = normalize(T * H_local.x + B * H_local.y + N * H_local.z);
	
	// Reflect to get light direction
	float3 L = reflect(-V, H);
	
	// Calculate PDF
	float D = GGX_D(H, N, T, B, roughness, anisotropic);
	float NdotH = max(dot(N, H), 0.0);
	float VdotH = max(dot(V, H), 0.0);
	pdf = D * NdotH / (4.0 * VdotH + 1e-7);
	
	return L;
}

// Sample GGX distribution (anisotropic) - 外部接口，保持兼容性
float3 SampleGGX(float3 N, float3 V, float roughness, float anisotropic, float anisotropic_rotation, 
                 inout uint seed, out float pdf) {
	float3 T, B;
	BuildOrthonormalBasis(N, T, B);
	return SampleGGX_Internal(N, V, T, B, roughness, anisotropic, anisotropic_rotation, seed, pdf);
}

// Sheen BRDF (Estevez & Kulla)
float3 EvaluateSheen(float3 V, float3 L, float3 N, float3 base_color, float sheen, float sheen_tint) {
	if (sheen < 1e-5) return float3(0, 0, 0);
	
	float3 H = normalize(V + L);
	float VdotH = max(dot(V, H), 0.0);
	
	// Sheen color
	float lum = dot(base_color, float3(0.299, 0.587, 0.114));
	float3 tint_color = lum > 0 ? base_color / lum : float3(1, 1, 1);
	float3 sheen_color = lerp(float3(1, 1, 1), tint_color, sheen_tint);
	
	// Schlick Fresnel approximation for sheen
	float fresnel = pow(1.0 - VdotH, 5.0);
	return sheen * sheen_color * fresnel;
}

// Clearcoat BRDF
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
	
	// Clearcoat uses a fixed IOR of 1.5
	float F0 = 0.04; // ((1.5 - 1) / (1.5 + 1))^2
	float F = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
	
	// GGX distribution for clearcoat
	float alpha = clearcoat_roughness * clearcoat_roughness;
	float alpha2 = alpha * alpha;
	float denom = NdotH * NdotH * (alpha2 - 1.0) + 1.0;
	float D = alpha2 / (PI * denom * denom + 1e-7);
	
	// Geometry term (simplified for clearcoat)
	float k = alpha / 2.0;
	float G_V = NdotV / (NdotV * (1.0 - k) + k);
	float G_L = NdotL / (NdotL * (1.0 - k) + k);
	float G = G_V * G_L;
	
	pdf = D * NdotH / (4.0 * VdotH + 1e-7);
	
	float clearcoat_value = clearcoat * 0.25 * F * D * G / (4.0 * NdotV * NdotL + 1e-7);
	return float3(clearcoat_value, clearcoat_value, clearcoat_value);
}

// Sample clearcoat lobe
float3 SampleClearcoat(float3 N, float3 V, float clearcoat_roughness, inout uint seed, out float pdf) {
	float u1 = Rand01(seed);
	float u2 = Rand01(seed);
	
	// GGX sampling for clearcoat
	float alpha = clearcoat_roughness * clearcoat_roughness;
	float alpha2 = alpha * alpha;
	
	float cos_theta = sqrt((1.0 - u1) / (u1 * (alpha2 - 1.0) + 1.0));
	float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
	float phi = 2.0 * PI * u2;
	
	// Build tangent space
	float3 T, B;
	BuildOrthonormalBasis(N, T, B);
	
	// Half vector
	float3 H = normalize(sin_theta * cos(phi) * T + sin_theta * sin(phi) * B + cos_theta * N);
	
	// Reflect to get light direction
	float3 L = reflect(-V, H);
	
	// Calculate PDF
	float NdotH = max(dot(N, H), 0.0);
	float VdotH = max(dot(V, H), 0.0);
	float D = alpha2 / (PI * pow(NdotH * NdotH * (alpha2 - 1.0) + 1.0, 2.0) + 1e-7);
	pdf = D * NdotH / (4.0 * VdotH + 1e-7);
	
	return L;
}

// Principled BSDF evaluation
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
	
	// Build tangent space for anisotropic
	float3 T, B;
	BuildOrthonormalBasis(N, T, B);
	
	// Specular reflection color
	float3 spec_color, F0;
	ComputeSpecularColor(mat, baseColor, spec_color, F0);
	
	// Fresnel
	float3 F = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
	
	// GGX specular
	float D = GGX_D(H, N, T, B, mat.roughness, mat.anisotropic);
	float G = GGX_G(V, L, N, T, B, mat.roughness, mat.anisotropic);
	
	// 改进的除零保护：使用更大的epsilon，并限制分母的最小值
	const float MIN_DENOM = 1e-5; // 更大的最小值保护
	float denominator = max(4.0 * NdotV * NdotL, MIN_DENOM);
	float3 specular = D * F * G / denominator;
	
	// 限制specular项的最大值，防止数值爆炸
	// 即使D、F、G都很大，specular也不应该超过合理范围
	const float MAX_SPECULAR = 1e3; // 合理的上限值
	specular = min(specular, float3(MAX_SPECULAR, MAX_SPECULAR, MAX_SPECULAR));
	
	// Diffuse (energy-conserving)
	float3 kD = (1.0 - F) * (1.0 - mat.metallic);
	float3 diffuse = kD * baseColor / PI;
	
	// Sheen
	float3 sheen = EvaluateSheen(V, L, N, baseColor, mat.sheen, mat.sheen_tint);
	
	// Clearcoat
	float clearcoat_pdf;
	float3 clearcoat = EvaluateClearcoat(V, L, N, mat.clearcoat, mat.clearcoat_roughness, clearcoat_pdf);
	
	// Combine lobes
	float3 brdf = diffuse + specular + sheen + clearcoat;
	
	// Calculate combined PDF
	float diffuse_weight, specular_weight, clearcoat_weight;
	ComputeLobeWeights(F, kD, mat.clearcoat, diffuse_weight, specular_weight, clearcoat_weight);
	
	float pdf_diffuse = NdotL / PI;
	float pdf_specular = D * NdotH / (4.0 * VdotH + 1e-7);
	
	pdf = diffuse_weight * pdf_diffuse + specular_weight * pdf_specular + clearcoat_weight * clearcoat_pdf;
	
	return brdf * NdotL;
}

// Sample Principled BSDF
float3 SamplePrincipledBSDF(Material mat, float3 V, float3 N, float2 uv, inout uint seed, out float pdf, out float3 weight) {
	float3 baseColor = GetMaterialBaseColor(mat, uv);
	
	// Build tangent space (预计算，避免在采样函数中重复计算)
	float3 T, B;
	BuildOrthonormalBasis(N, T, B);
	
	// Calculate lobe weights
	float VdotH_approx = max(dot(V, N), 0.0);
	
	float3 spec_color, F0;
	ComputeSpecularColor(mat, baseColor, spec_color, F0);
	float3 F_approx = F0 + (1.0 - F0) * pow(1.0 - VdotH_approx, 5.0);
	
	float3 kD = (1.0 - F_approx) * (1.0 - mat.metallic);
	
	float diffuse_weight, specular_weight, clearcoat_weight;
	ComputeLobeWeights(F_approx, kD, mat.clearcoat, diffuse_weight, specular_weight, clearcoat_weight);
	
	// Choose lobe to sample
	float lobe_choice = Rand01(seed);
	float3 L;
	
	if (lobe_choice < diffuse_weight) {
		// Sample diffuse lobe
		L = SampleCosineHemisphere(N, seed, pdf);
		weight = float3(1, 1, 1); // Will be multiplied by BRDF evaluation
	} else if (lobe_choice < diffuse_weight + specular_weight) {
		// Sample specular lobe (使用预计算的 T, B)
		L = SampleGGX_Internal(N, V, T, B, mat.roughness, mat.anisotropic, mat.anisotropic_rotation, seed, pdf);
		weight = float3(1, 1, 1);
	} else {
		// Sample clearcoat lobe
		L = SampleClearcoat(N, V, mat.clearcoat_roughness, seed, pdf);
		weight = float3(1, 1, 1);
	}
	
	// Evaluate full BSDF to get actual weight
	float eval_pdf;
	float3 brdf = EvaluatePrincipledBSDF(mat, V, L, N, uv, eval_pdf);
	
	// Update PDF to be the combined PDF
	pdf = eval_pdf;
	
	// Weight is BRDF * NdotL / PDF (but BRDF already includes NdotL)
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

