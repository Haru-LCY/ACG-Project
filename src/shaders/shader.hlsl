struct CameraInfo {
  float4x4 screen_to_camera;
  float4x4 camera_to_world;
  float aperture;        // 光圈大小
  float focus_distance;  // 焦距
        float exposure;       // 曝光乘数（亮度缩放）
        int samples_per_pixel; // 每帧每像素样本数
        int debug_mode;        // 0=off,1=show-only-debug-point-light
        int debug_point_index; // which point light index to debug (0..N-1)
        int padding0;          // 对齐
};

// Principled BSDF Material (matches C++ struct layout)
struct Material {
  // Base properties
  float3 base_color;
  float roughness;
  
  float metallic;
  float specular;
  float specular_tint;
  float anisotropic;
  
  float anisotropic_rotation;
  float sheen;
  float sheen_tint;
  float clearcoat;
  
  float clearcoat_roughness;
  float transmission;
  float transmission_roughness;
  float ior;
  
  float3 transmission_color;
  float subsurface;
  
  float3 subsurface_color;
  float padding1;
  
  float3 subsurface_radius;
  float padding2;
  
  float3 emission_color;
  float emission_strength;
  
  float alpha_threshold;
  float has_alpha_map;
  int texture_id;
  float padding3;
};

struct HoverInfo {
  int hovered_entity_id;
};

// 点光源结构体
struct PointLight {
  float3 position;     // 光源位置
  float strength;      // 光源强度
  float3 color;        // 光源颜色
  float radius;        // 光源半径（用于软阴影）
};

//面光源结构体
struct AreaLight {
    float3 position;     // 光源中心位置
    float strength;      // 总辐射功率（单位：瓦特）
    float3 color;        // 光源颜色 (RGB, 范围0-1)
    float width;         // 光源宽度（米）
    float3 direction;    // 光源法线方向（归一化）
    float height;        // 光源高度（米）
    float3 u_axis;       // 宽度方向轴（归一化）
    float pad1;
    float3 v_axis;       // 高度方向轴（归一化）
    float pad2;
};

RaytracingAccelerationStructure as : register(t0, space0);
RWTexture2D<float4> output : register(u0, space1);
ConstantBuffer<CameraInfo> camera_info : register(b0, space2);
StructuredBuffer<Material> materials : register(t0, space3);
ConstantBuffer<HoverInfo> hover_info : register(b0, space4);
RWTexture2D<int> entity_id_output : register(u0, space5);
RWTexture2D<float4> accumulated_color : register(u0, space6);
RWTexture2D<int> accumulated_samples : register(u0, space7);
RWTexture2D<float> depth_output : register(u0, space12);
StructuredBuffer<PointLight> point_lights : register(t0, space8);  // 点光源数组
StructuredBuffer<AreaLight> area_lights : register(t0, space9);  // 面光源数组
Texture2D textures[16] : register(t0, space10);  // 纹理数组 (最多16个)
SamplerState texSampler : register(s0, space11);  // 纹理采样器
//t，u，space分别表示纹理寄存器、采样器寄存器和常量缓冲区寄存器的空间索引

struct RayPayload {
	float3 radiance;
	float3 throughput;
	bool hit;
	uint material_idx;
	float3 hit_pos;
	float3 normal;
	float2 barycentrics;
	uint primitive_id;
	float2 uv;  // UV坐标用于纹理采样
};

// Debug: shadow visibility boost (用于临时放大 lightVisibilityRGB 以便调试)
static const float SHADOW_DEBUG_BOOST = 1.0; //1.0相当于正常
static const float PI = 3.14159265359;

// 改进的 PCG RNG
uint PCGHash(inout uint state) {
	uint prev = state * 747796405u + 2891336453u;
	uint word = ((prev >> ((prev >> 28u) + 4u)) ^ prev) * 277803737u;
	state = prev;
	return (word >> 22u) ^ word;
}

float Rand01(inout uint state) {
	return float(PCGHash(state)) / 4294967296.0;
}

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
	float theta = 2.0 * 3.14159265359 * u2;
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

// GGX Distribution (with anisotropic support)
float GGX_D(float3 H, float3 N, float3 T, float3 B, float roughness, float anisotropic) {
	float aspect = sqrt(1.0 - anisotropic * 0.9);
	float alpha_x = roughness * roughness / aspect;
	float alpha_y = roughness * roughness * aspect;
	
	float NdotH = dot(N, H);
	float TdotH = dot(T, H);
	float BdotH = dot(B, H);
	
	float a2 = alpha_x * alpha_y;
	float3 v = float3(alpha_y * TdotH, alpha_x * BdotH, a2 * NdotH);
	float v2 = dot(v, v);
	float w2 = a2 / v2;
	return a2 * w2 * w2 / PI;
}

// GGX Geometry term (Smith)
float GGX_G1(float3 V, float3 N, float3 T, float3 B, float roughness, float anisotropic) {
	float aspect = sqrt(1.0 - anisotropic * 0.9);
	float alpha_x = roughness * roughness / aspect;
	float alpha_y = roughness * roughness * aspect;
	
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

// Sample GGX distribution (anisotropic)
float3 SampleGGX(float3 N, float3 V, float roughness, float anisotropic, float anisotropic_rotation, 
                 inout uint seed, out float pdf) {
	float u1 = Rand01(seed);
	float u2 = Rand01(seed);
	
	// Build tangent space
	float3 T, B;
	BuildOrthonormalBasis(N, T, B);
	
	// Apply anisotropic rotation
	float rotation_angle = anisotropic_rotation * 2.0 * PI;
	float cos_rot = cos(rotation_angle);
	float sin_rot = sin(rotation_angle);
	float3 T_rot = cos_rot * T + sin_rot * B;
	float3 B_rot = -sin_rot * T + cos_rot * B;
	T = T_rot;
	B = B_rot;
	
	// Sample with anisotropy
	float aspect = sqrt(1.0 - anisotropic * 0.9);
	float alpha_x = roughness * roughness / aspect;
	float alpha_y = roughness * roughness * aspect;
	
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
	
	return float3(clearcoat * 0.25 * F * D * G / (4.0 * NdotV * NdotL + 1e-7), 
	              clearcoat * 0.25 * F * D * G / (4.0 * NdotV * NdotL + 1e-7),
	              clearcoat * 0.25 * F * D * G / (4.0 * NdotV * NdotL + 1e-7));
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
	float lum = dot(baseColor, float3(0.299, 0.587, 0.114));
	float3 tint_color = lum > 0 ? baseColor / lum : float3(1, 1, 1);
	float3 spec_color = lerp(float3(1, 1, 1), tint_color, mat.specular_tint);
	float3 F0 = lerp(0.08 * mat.specular * spec_color, baseColor, mat.metallic);
	
	// Fresnel
	float3 F = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
	
	// GGX specular
	float D = GGX_D(H, N, T, B, mat.roughness, mat.anisotropic);
	float G = GGX_G(V, L, N, T, B, mat.roughness, mat.anisotropic);
	float3 specular = D * F * G / (4.0 * NdotV * NdotL + 1e-7);
	
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
	float diffuse_weight = max(max(kD.x, kD.y), kD.z);
	float specular_weight = max(max(F.x, F.y), F.z);
	float clearcoat_weight = mat.clearcoat * 0.25;
	
	float total_weight = diffuse_weight + specular_weight + clearcoat_weight + 1e-7;
	diffuse_weight /= total_weight;
	specular_weight /= total_weight;
	clearcoat_weight /= total_weight;
	
	float pdf_diffuse = NdotL / PI;
	float pdf_specular = D * NdotH / (4.0 * VdotH + 1e-7);
	
	pdf = diffuse_weight * pdf_diffuse + specular_weight * pdf_specular + clearcoat_weight * clearcoat_pdf;
	
	return brdf * NdotL;
}

// Sample Principled BSDF
float3 SamplePrincipledBSDF(Material mat, float3 V, float3 N, float2 uv, inout uint seed, out float pdf, out float3 weight) {
	float3 baseColor = GetMaterialBaseColor(mat, uv);
	
	// Build tangent space
	float3 T, B;
	BuildOrthonormalBasis(N, T, B);
	
	// Calculate lobe weights
	float3 H = N; // temporary
	float VdotH_approx = max(dot(V, N), 0.0);
	
	float lum = dot(baseColor, float3(0.299, 0.587, 0.114));
	float3 tint_color = lum > 0 ? baseColor / lum : float3(1, 1, 1);
	float3 spec_color = lerp(float3(1, 1, 1), tint_color, mat.specular_tint);
	float3 F0 = lerp(0.08 * mat.specular * spec_color, baseColor, mat.metallic);
	float3 F_approx = F0 + (1.0 - F0) * pow(1.0 - VdotH_approx, 5.0);
	
	float3 kD = (1.0 - F_approx) * (1.0 - mat.metallic);
	
	float diffuse_weight = max(max(kD.x, kD.y), kD.z);
	float specular_weight = max(max(F_approx.x, F_approx.y), F_approx.z);
	float clearcoat_weight = mat.clearcoat * 0.25;
	
	float total_weight = diffuse_weight + specular_weight + clearcoat_weight + 1e-7;
	diffuse_weight /= total_weight;
	specular_weight /= total_weight;
	clearcoat_weight /= total_weight;
	
	// Choose lobe to sample
	float lobe_choice = Rand01(seed);
	float3 L;
	
	if (lobe_choice < diffuse_weight) {
		// Sample diffuse lobe
		L = SampleCosineHemisphere(N, seed, pdf);
		weight = float3(1, 1, 1); // Will be multiplied by BRDF evaluation
	} else if (lobe_choice < diffuse_weight + specular_weight) {
		// Sample specular lobe
		L = SampleGGX(N, V, mat.roughness, mat.anisotropic, mat.anisotropic_rotation, seed, pdf);
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
	if (pdf > 1e-7) {
		weight = brdf / pdf;
	} else {
		weight = float3(0, 0, 0);
	}
	
	return L;
}

// 在光圈上均匀采样一个点(用于景深效果)
// 返回一个在单位圆盘内的随机点
float2 SampleUnitDisk(inout uint seed) {
    float r = sqrt(Rand01(seed));
    float theta = 2.0 * PI * Rand01(seed);
    return float2(r * cos(theta), r * sin(theta));
}

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


// [新增] ACES Tone Mapping (解决过曝/刺眼问题的关键)
float3 ACESFilm(float3 x) {
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// [新增] 计算面光源贡献 (使用 Principled BSDF)
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

// ... (保留原有的 PointLight 计算函数) ...



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

[shader("raygeneration")] void RayGenMain() {
    // ... (保留原有的像素坐标计算和 Ray 初始化代码) ...
    uint2 dispatchIndex = DispatchRaysIndex().xy;
    int prev_samples = accumulated_samples[dispatchIndex];
    uint seed = (uint)dispatchIndex.x * 1973u + (uint)dispatchIndex.y * 9277u + (uint)prev_samples * 26699u;
    seed = PCGHash(seed);
    seed = PCGHash(seed);

    int spp = max(1, camera_info.samples_per_pixel);
    float3 radianceSum = float3(0,0,0);
    RayPayload lastPayload; // keep last payload for debug

    // --- Deterministic pick ray for stable entity ID (no jitter, no DOF)
    RayPayload pickPayload;
    pickPayload.hit = false;
    pickPayload.material_idx = 0;    
    {
        float2 pixel_center0 = (float2)dispatchIndex + float2(0.5, 0.5);
        float2 uv0 = pixel_center0 / float2(DispatchRaysDimensions().xy);
        uv0.y = 1.0 - uv0.y;
        float2 d0 = uv0 * 2.0 - 1.0;
        float4 origin40 = mul(camera_info.camera_to_world, float4(0, 0, 0, 1));
        float4 target0 = mul(camera_info.screen_to_camera, float4(d0, 1, 1));
        float4 direction40 = mul(camera_info.camera_to_world, float4(target0.xyz, 0));
        float3 pickOrigin = origin40.xyz;
        float3 pickDir = normalize(direction40.xyz);

        RayDesc pickRay;
        pickRay.Origin = pickOrigin;
        pickRay.Direction = pickDir;
        pickRay.TMin = 0.001;
        pickRay.TMax = 10000.0;
        TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, pickRay, pickPayload);
        // Write depth (distance) into the depth buffer (0.0 if no hit)
        float dval = 0.0;
        if (pickPayload.hit) {
            // origin4 is camera world origin for this pixel
            float3 origin = origin40.xyz;
            dval = length(pickPayload.hit_pos - origin);
        }
        depth_output[dispatchIndex] = dval;
    }

    for (int s = 0; s < spp; ++s) {
        // advance RNG for new sample
        seed = PCGHash(seed);
        float jitter_x = Rand01(seed) - 0.5;
        float jitter_y = Rand01(seed) - 0.5;
        float2 pixel_center = (float2)dispatchIndex + float2(0.5 + jitter_x, 0.5 + jitter_y);
        float2 uv = pixel_center / float2(DispatchRaysDimensions().xy);
        uv.y = 1.0 - uv.y;
        float2 d = uv * 2.0 - 1.0;

        // 计算初始相机位置和射线方向
        float4 origin4 = mul(camera_info.camera_to_world, float4(0, 0, 0, 1));
        float4 target = mul(camera_info.screen_to_camera, float4(d, 1, 1));
        float4 direction4 = mul(camera_info.camera_to_world, float4(target.xyz, 0));

        float3 rayOrigin = origin4.xyz;
        float3 rayDir = normalize(direction4.xyz);
    
    // ===== 景深效果 (Depth of Field) =====
    if (camera_info.aperture > 0.0001) {
        // 计算焦点位置(沿着原始光线方向在焦距处的点)
        float3 focalPoint = rayOrigin + rayDir * camera_info.focus_distance;
        
        // 在光圈上随机采样一个偏移
        float2 diskSample = SampleUnitDisk(seed);
        float2 lensOffset = diskSample * camera_info.aperture;
        
        // 计算相机的右向量和上向量
        float3 cameraRight = normalize(mul(camera_info.camera_to_world, float4(1, 0, 0, 0)).xyz);
        float3 cameraUp = normalize(mul(camera_info.camera_to_world, float4(0, 1, 0, 0)).xyz);
        
        // 偏移光线原点(模拟从光圈不同位置发出)
        rayOrigin = rayOrigin + cameraRight * lensOffset.x + cameraUp * lensOffset.y;
        
        // 重新计算光线方向使其指向焦点
        rayDir = normalize(focalPoint - rayOrigin);
    }

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
        // 仅在第一次弹射，或者(可选)每次漫反射/粗糙镜面弹射后计算
        // 这里为了简化，只在 bounce == 0 时计算所有光源，或者每次bounce都算（更准确）
        // 建议：每次bounce都计算，但要处理好权重(MIS)，这里用简单的纯NEE逻辑
        
        // 如果是镜面反射(roughness很低)或玻璃折射，通常不进行NEE，由光线追踪隐式处理
        // 但为了看到光源的高光，我们允许计算Specular部分的NEE
        
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
        // accumulate this sample
        radianceSum += radiance;
        lastPayload = payload;
    }
    
    // ================== 5. 最终输出处理 (Tone Mapping) ==================
    
    // 累积颜色
    float4 prev_color = accumulated_color[dispatchIndex];
    // 注意：Radiance 可能非常大 (HDR)，需要累积 HDR 值
    float4 new_sum = prev_color + float4(radianceSum, (float)spp);
    int new_count = prev_samples + spp;
    
    accumulated_color[dispatchIndex] = new_sum;
    accumulated_samples[dispatchIndex] = new_count;
    
    // 计算平均值
    float3 hdrColor = new_sum.rgb / float(new_count);

    // Apply global exposure multiplier from camera settings
    hdrColor *= camera_info.exposure;
    
    // [关键] 应用 Tone Mapping (HDR -> LDR)
    // 这将把 (20, 50, 20) 这样的亮度映射回 (0.9, 1.0, 0.9) 而不是截断
    float3 mappedColor = ACESFilm(hdrColor);
    
    // Gamma 校正
    mappedColor = pow(mappedColor, 1.0 / 2.2);
    
    output[dispatchIndex] = float4(mappedColor, 1.0);
    entity_id_output[dispatchIndex] = pickPayload.hit ? (int)pickPayload.material_idx : -1;
}

[shader("miss")] void MissMain(inout RayPayload payload) {
	float t = 0.5 * (normalize(WorldRayDirection()).y + 1.0);
	payload.radiance = lerp(float3(1.0, 1.0, 1.0), float3(0.5, 0.7, 1.0), t);
	payload.hit = false;
	payload.material_idx = 0xFFFFFFFF;
}

[shader("closesthit")] void ClosestHitMain(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attr) {
	payload.hit = true;
	payload.material_idx = InstanceID();
	payload.primitive_id = PrimitiveIndex();
	payload.barycentrics = attr.barycentrics;
	
	float t = RayTCurrent();
	payload.hit_pos = WorldRayOrigin() + WorldRayDirection() * t;
	
	// 使用物体空间位置计算几何法线
	float3 worldPos = payload.hit_pos;
	float3 objectPos = mul(WorldToObject3x4(), float4(worldPos, 1.0)).xyz;
	float3 objectNormal;
	
	// 根据实体ID来判断几何体类型
	// Entity 0-4: 房间墙壁（立方体，需要平面法线）
	// Entity 5-6: 八面体（需要平滑法线）
	// Entity 7: 玻璃立方体（需要平面法线）
	uint entity_id = InstanceID();
	
	// 对墙壁(0-4)和玻璃立方体(7)使用面法线
	if (entity_id <= 4 || entity_id == 7) {
		// 立方体面法线计算
		float3 absPos = abs(objectPos);
		float maxComp = max(max(absPos.x, absPos.y), absPos.z);
		
		// 找到最大分量对应的面，使用该面的法线
		if (abs(absPos.x - maxComp) < 0.01) {
			objectNormal = float3(sign(objectPos.x), 0, 0);
		} else if (abs(absPos.y - maxComp) < 0.01) {
			objectNormal = float3(0, sign(objectPos.y), 0);
		} else if (abs(absPos.z - maxComp) < 0.01) {
			objectNormal = float3(0, 0, sign(objectPos.z));
		} else {
			objectNormal = normalize(objectPos);
		}
	} else {
		// 八面体(5-6)：使用平滑的归一化法线（金属质感）
		objectNormal = normalize(objectPos);
	}
	
	// 转换到世界空间
	float3x3 objectToWorld = (float3x3)ObjectToWorld3x4();
	payload.normal = normalize(mul(objectToWorld, objectNormal));
	
	// 确保法线朝向光线来源
	if (dot(payload.normal, -WorldRayDirection()) < 0) {
		payload.normal = -payload.normal;
	}
	
	// 计算UV坐标
	float u, v;
	
	// 立方体(0-4, 7)：使用平面UV映射
	if (entity_id <= 4 || entity_id == 7) {
		float3 absNormal = abs(payload.normal);
		if (absNormal.x > absNormal.y && absNormal.x > absNormal.z) {
			// X面
			if (payload.normal.x > 0) {
				u = (objectPos.z + 1.0) / 2.0;
				v = 1.0 - (objectPos.y + 1.0) / 2.0;
			} else {
				u = (1.0 - objectPos.z) / 2.0;
				v = 1.0 - (objectPos.y + 1.0) / 2.0;
			}
		} else if (absNormal.y > absNormal.z) {
			// Y面
			if (payload.normal.y > 0) {
				u = (objectPos.x + 1.0) / 2.0;
				v = 1.0 - (1.0 - objectPos.z) / 2.0;
			} else {
				u = (objectPos.x + 1.0) / 2.0;
				v = 1.0 - (objectPos.z + 1.0) / 2.0;
			}
		} else {
			// Z面
			if (payload.normal.z > 0) {
				u = (objectPos.x + 1.0) / 2.0;
				v = 1.0 - (objectPos.y + 1.0) / 2.0;
			} else {
				u = (1.0 - objectPos.x) / 2.0;
				v = 1.0 - (objectPos.y + 1.0) / 2.0;
			}
		}
		float scale = 1.0;
		u *= scale;
		v *= scale;
	} else {
		// 八面体(5-6)：使用球面映射
		float3 normalizedPos = normalize(objectPos);
		u = 0.5 + atan2(normalizedPos.z, normalizedPos.x) / (2.0 * 3.14159265359);
		v = 0.5 - asin(normalizedPos.y) / 3.14159265359;
	}
	
	payload.uv = float2(u, v);
}