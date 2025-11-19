struct CameraInfo {
  float4x4 screen_to_camera;
  float4x4 camera_to_world;
  float aperture;        // 光圈大小
  float focus_distance;  // 焦距
    int samples_per_pixel; // 每帧每像素样本数
    int padding0;          // 对齐
};

struct Material {
  float3 base_color;
  float roughness;
  float metallic;
  float transmission;  // 透明度
	float3 transmission_color; // 透射颜色/吸收色（用于有色玻璃的 Beer–Lambert 衰减）
	float ior;           // 折射率
  float alpha_threshold; // alpha shadow 阈值
  float has_alpha_map;   // 是否有透明度贴图
  int texture_id;        // 纹理ID：-1=无纹理, >=0=纹理索引
  float3 padding;        // 对齐到16字节
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

// Lambertian 漫反射采样
float3 SampleCosineHemisphere(float3 n, inout uint seed) {
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
	return normalize(x * t + y * b + z * n);
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

// GGX importance sampling for specular
float3 SampleGGX(float3 N, float3 V, float roughness, inout uint seed) {
	float a = roughness * roughness;
	a = a * a; // 平方一次以增加低粗糙度时的采样效率
	float u1 = Rand01(seed);
	float u2 = Rand01(seed);
	
	// 避免极端情况
	u1 = max(u1, 0.00001);
	
	float theta = atan(a * sqrt(u1) / sqrt(max(0.00001, 1.0 - u1)));
	float phi = 2.0 * 3.14159265359 * u2;
	
	float3 H;
	H.x = sin(theta) * cos(phi);
	H.y = cos(theta);
	H.z = sin(theta) * sin(phi);
	
	// Build tangent space
	float3 up = abs(N.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
	float3 T = normalize(cross(up, N));
	float3 B = cross(N, T);
	
	H = normalize(T * H.x + N * H.y + B * H.z);
	return normalize(2.0 * dot(V, H) * H - V);
}

// 在光圈上均匀采样一个点(用于景深效果)
// 返回一个在单位圆盘内的随机点
float2 SampleUnitDisk(inout uint seed) {
    float r = sqrt(Rand01(seed));
    float theta = 2.0 * PI * Rand01(seed);
    return float2(r * cos(theta), r * sin(theta));
}


// =========================================================================
// 新增函数：PBR 辅助函数
// =========================================================================

// 计算 GGX NDF D项
float DistributionGGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH2 = NdotH * NdotH;
    float denom = NdotH2 * (a2 - 1.0) + 1.0;
    return a2 / (PI * denom * denom);
}

// 计算 GGX Smith Masking-Shadowing G项 (Schlick-GGX近似)
float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

// 计算 GGX 几何项 G
float GeometrySmith(float NdotV, float NdotL, float roughness) {
    return GeometrySchlickGGX(NdotV, roughness) * GeometrySchlickGGX(NdotL, roughness);
}

// 计算 Cook-Torrance PBR BRDF (仅考虑反射部分)
float3 CookTorranceBRDF(float3 L, float3 V, float3 N, float3 baseColor, float roughness, float metallic, out float3 specularF0) {
    float3 H = normalize(V + L);
    float NdotL = max(dot(N, L), 0.0);
    float NdotV = max(dot(N, V), 0.0);
    float NdotH = max(dot(N, H), 0.0);
    float VdotH = max(dot(V, H), 0.0);
    
    // Fresnel
    specularF0 = lerp(float3(0.04, 0.04, 0.04), baseColor, metallic);
    float3 F = FresnelSchlick(VdotH, specularF0);
    
    // Normal Distribution Function (NDF)
    float D = DistributionGGX(NdotH, roughness);
    
    // Geometry Term (G)
    float G = GeometrySmith(NdotV, NdotL, roughness);
    
    // Specular Term
    float3 specular = (D * F * G) / max(4.0 * NdotV * NdotL, 0.001);
    
    // Diffuse Term (Oren-Nayar/Lambertian)
    float3 kD = (1.0 - F) * (1.0 - metallic);
    float3 diffuse = baseColor * (1.0 - metallic) / PI;
    
    return kD * diffuse + specular;
}

// 计算 GGX/Cosine 联合采样的 PDF 值
float CalculateBSDFPdf(float3 L, float3 V, float3 N, float roughness, float metallic, float3 F0, bool isSpecularSample) {
    float NdotL = max(dot(N, L), 0.0);
    if (NdotL <= 0.0) return 0.0;
    
    if (metallic > 0.99) { // 纯金属（只做镜面采样）
        // GGX 采样的 PDF (基于微面元法线 H)
        float3 H = normalize(V + L);
        float NdotH = max(dot(N, H), 0.0);
        float HdotL = max(dot(H, L), 0.0);
        float D = DistributionGGX(NdotH, roughness);
        return D * NdotH / (4.0 * HdotL);
    } else { // 电介质/混合（漫反射 + 镜面反射）
        // 概率加权混合
        float3 F = FresnelSchlick(max(dot(N, V), 0.0), F0);
        // 使用平均菲涅尔项作为镜面反射概率P_s
        float P_s = (F.x + F.y + F.z) / 3.0; 
        P_s = clamp(P_s, 0.1, 0.9); // 增加鲁棒性
        float P_d = 1.0 - P_s; // 漫反射概率
        
        // 漫反射 PDF: Cosine Hemisphere Sampling
        float pdf_d = NdotL / PI; 
        
        // 镜面反射 PDF: GGX Importance Sampling (同纯金属)
        float3 H = normalize(V + L);
        float NdotH = max(dot(N, H), 0.0);
        float HdotL = max(dot(H, L), 0.0);
        float D = DistributionGGX(NdotH, roughness);
        float pdf_s = D * NdotH / (4.0 * HdotL);
        
        // 联合 PDF
        if (isSpecularSample) {
            // 如果本次是Specular采样（但目标光线是L），则其自身PDF是P_s * pdf_s，另一个是P_d * pdf_d
            return P_s * pdf_s + P_d * pdf_d;
        } else {
             // 否则，认为是漫反射采样（但目标光线是L），则其自身PDF是P_d * pdf_d，另一个是P_s * pdf_s
             return P_d * pdf_d + P_s * pdf_s;
        }
    }
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

// [修改] 计算面光源贡献 (包含对透明/金属的特殊处理)
float3 ComputeAreaLightContribution(float3 hitPos, float3 normal, float3 viewDir, Material material, float2 uv, AreaLight light, inout uint seed, out float pdf_light, out float3 sampledDir) {
    // 1. 在面光源上随机采样一个点
    float u = Rand01(seed) - 0.5f; // [-0.5, 0.5]
    float v = Rand01(seed) - 0.5f; // [-0.5, 0.5]
    
    float3 samplePos = light.position + (light.u_axis * u * light.width) + (light.v_axis * v * light.height);
    
    // 2. 几何计算
    float3 lightVec = samplePos - hitPos;
    float distSq = dot(lightVec, lightVec);
    float dist = sqrt(distSq);
    float3 lightDir = lightVec / dist;
    sampledDir = lightDir;
    
    float NdotL = dot(normal, lightDir);
    float3 lightNormal = light.direction; // 面光源朝向
    float LdotLn = dot(-lightDir, lightNormal); // 光源表面法线与光线的夹角
    
    // 剔除：光源在背面 或 光源本身背对物体
    if (NdotL <= 0.0 || LdotLn <= 0.0) {
        pdf_light = 0.0;
        return float3(0,0,0);
    }
    
    // 3. 阴影检测
    const float RAY_EPSILON = 0.001;
    float3 visibility = TraceAlphaShadowRGB(hitPos + normal * RAY_EPSILON, lightDir, dist - RAY_EPSILON, seed);
    
    if (max(max(visibility.r, visibility.g), visibility.b) < 0.001) {
        pdf_light = 0.0;
        return float3(0,0,0);
    }
    
    // 4. 辐射度计算 (Monte Carlo Integration)
    float area = light.width * light.height;
    float3 Le = light.color * light.strength; 
    
    // *************************************************************
    // [MIS 核心] 计算光源采样的 PDF (pdf_light)
    // p(w_i) = p_A(x_i) * |(x_i - x_0)|^2 / |n_i . (x_i - x_0)|
    // p_A(x_i) 是面光源表面上的均匀采样密度 = 1 / Area
    float pdf_area = 1.0 / area;
    pdf_light = pdf_area * distSq / LdotLn; // LdotLn 是 |n_light . L_vec| / dist
    // *************************************************************

    // 5. BRDF 计算 - 使用纹理颜色
    float3 baseColor = GetMaterialBaseColor(material, uv);
    float3 F0_unused;
    float3 brdf = CookTorranceBRDF(lightDir, viewDir, normal, baseColor, material.roughness, material.metallic, F0_unused);

    // 6. 最终光照贡献 = Le * BRDF * NdotL * (1/pdf_light) * visibility
    // Monte Carlo 积分估计：f(X_i) / p(X_i)
    // f(X_i) = Le * BRDF * NdotL * (Geometry Term * Area)
    // p(X_i) = 1 / Area * dist^2 / LdotLn
    // 最终贡献 = Le * BRDF * NdotL * (LdotLn * Area / distSq) * visibility / (pdf_light)
    // 简化后：
    float Le_pdf = (Le * NdotL * LdotLn) / distSq;
    
    return Le_pdf * brdf * area * visibility;
}

// ... (保留原有的 PointLight 计算函数) ...



// 计算点光源的直接光照贡献
// 参数：
//   hitPos: 着色点位置
//   normal: 着色点法线
//   viewDir: 视线方向（指向观察者）
//   material: 材质属性
//   uv: UV坐标用于纹理采样
//   light: 点光源数据
//   seed: 随机数种子（用于软阴影采样）
// 返回：该点光源对着色点的光照贡献（RGB颜色）
float3 ComputePointLightContribution(float3 hitPos, float3 normal, float3 viewDir, Material material, float2 uv, PointLight light, inout uint seed) {
	// 计算光源方向和距离
	float3 lightVec = light.position - hitPos;
	float lightDistance = length(lightVec);
	float3 lightDir = lightVec / lightDistance;  // 归一化光源方向
	
	// 计算光照衰减（平方反比定律）
	// 强度 = 光源强度 / (4π * 距离²)
	float attenuation = light.strength / (4.0 * 3.14159265359 * lightDistance * lightDistance);
	
	// 检查光源是否在表面的正面
	float NdotL = dot(normal, lightDir);
	if (NdotL <= 0.0) {
		return float3(0.0, 0.0, 0.0);  // 光源在表面背面，无贡献
	}
	
	// 检查阴影遮挡
	const float RAY_EPSILON = 0.001;
	float3 shadowOrigin = hitPos + normal * RAY_EPSILON;
	float3 lightVisibility = TraceAlphaShadowRGB(shadowOrigin, lightDir, lightDistance, seed);
	
	// 如果完全被遮挡，返回零
	if (max(max(lightVisibility.r, lightVisibility.g), lightVisibility.b) < 0.001) {
		return float3(0.0, 0.0, 0.0);
	}
	
    // 计算漫反射项（Lambertian BRDF）- 使用纹理颜色
    // 漫反射反射率 = baseColor * (1 - metallic)
    float3 baseColor = GetMaterialBaseColor(material, uv);
    float3 diffuseAlbedo = baseColor * (1.0 - material.metallic);
    float3 diffuse = diffuseAlbedo / 3.14159265359;  // Lambert BRDF = albedo/π (no NdotL here)
	
	// 计算镜面反射项（基于Cook-Torrance微表面模型的简化）
	float3 halfVec = normalize(lightDir + viewDir);  // 半程向量
	float NdotH = max(dot(normal, halfVec), 0.0);
	float NdotV = max(dot(normal, viewDir), 0.0);
	
	// Fresnel项（使用Schlick近似）
	float3 F0 = lerp(float3(0.04, 0.04, 0.04), baseColor, material.metallic);
	float VdotH = max(dot(viewDir, halfVec), 0.0);
	float3 F = FresnelSchlick(VdotH, F0);
	
	// GGX法线分布函数（简化版）
	float alpha = material.roughness * material.roughness;
	float alpha2 = alpha * alpha;
	float NdotH2 = NdotH * NdotH;
	float denom = NdotH2 * (alpha2 - 1.0) + 1.0;
	float D = alpha2 / (3.14159265359 * denom * denom);
	
	// 几何遮蔽项（Smith-GGX简化）
	float k = (material.roughness + 1.0) * (material.roughness + 1.0) / 8.0;
	float G1_V = NdotV / (NdotV * (1.0 - k) + k);
	float G1_L = NdotL / (NdotL * (1.0 - k) + k);
	float G = G1_V * G1_L;
	
	// 镜面反射 BRDF = (D * F * G) / (4 * NdotV * NdotL)
	float3 specular = (D * F * G) / max(4.0 * NdotV * NdotL, 0.001);
	
	// 合并漫反射和镜面反射
	// 注意：(1 - F) 确保能量守恒，金属没有漫反射
	float3 kD = (1.0 - F) * (1.0 - material.metallic);
	float3 brdf = kD * diffuse + specular;
	
    // 最终光照 = BRDF * 光源颜色 * 衰减 * NdotL * 可见性
	float3 radiance = brdf * light.color * attenuation * NdotL * lightVisibility * SHADOW_DEBUG_BOOST;
	
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

        const int MAX_BOUNCES = 10; // 50太高了，通常 8-12 就够了，性能更好
    RayPayload payload;
        float3 radiance = float3(0,0,0);
        float3 throughput = float3(1,1,1);
        // BSDF sampling metadata for MIS and throughput updates
        float pdf_bsdf = 1.0;
        float3 f_bsdf = float3(1.0, 1.0, 1.0);
    
    for (int bounce = 0; bounce < MAX_BOUNCES; ++bounce) {
        // --- 俄罗斯轮盘赌 (Russian Roulette) 终止路径 ---
        if (bounce > 3) {
            float p = max(max(throughput.r, throughput.g), throughput.b);
            float continuationProb = max(0.05, p); // 最小概率 0.05，防止过度终止
            if (Rand01(seed) > continuationProb) break;
            throughput /= continuationProb;
        }
        
        RayDesc ray;
        ray.Origin = rayOrigin;
        ray.Direction = rayDir;
        ray.TMin = 0.001;
        ray.TMax = 10000.0;
        TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);
        
        if (!payload.hit) {
            // Skybox / Environment
            float3 rayDirNorm = normalize(rayDir);
            float tsky = 0.5 * (rayDirNorm.y + 1.0);
            float3 sky = lerp(float3(0.1, 0.1, 0.15), float3(0.2, 0.25, 0.35), tsky); //稍微调暗环境光配合点光源
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
                
                float pdf_light_area = 0.0;
                float3 sampledDir = float3(0,0,0);
                float3 areaLightContrib = ComputeAreaLightContribution(hitPos, N, V, mat, uv, al, seed, pdf_light_area, sampledDir);
                if (pdf_light_area <= 0.0) continue;

                // 计算对应的 BSDF pdf（即：如果我们用 BSDF 采样，会采到该方向的概率）
                float3 F0_for_pdf = lerp(float3(0.04, 0.04, 0.04), GetMaterialBaseColor(mat, uv), mat.metallic);
                float pdf_bsdf_for_light = CalculateBSDFPdf(sampledDir, V, N, mat.roughness, mat.metallic, F0_for_pdf, false);

                // MIS 权重（Power heuristic）
                float w_light = 1.0;
                float denom = pdf_light_area * pdf_light_area + pdf_bsdf_for_light * pdf_bsdf_for_light;
                if (denom > 0.0) w_light = (pdf_light_area * pdf_light_area) / denom;

                radiance += throughput * areaLightContrib * w_light;
            }
        } 

        // ===== 间接光照 (BSDF Sampling / 递归) =====
        
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
                // 反射为 delta（镜面）采样，pdf = Fr
                pdf_bsdf = Fr;
                f_bsdf = float3(Fr, Fr, Fr);
            } else {
                // 折射
                float3 refracted;
                if (Refract(-V, normal, etaI/etaT, refracted)) {
                    rayDir = normalize(refracted);
                    rayOrigin = hitPos - normal * 0.001;
                    // Beer's Law 吸收 - 使用纹理颜色
                    if (entering) throughput *= baseColor; // 使用纹理颜色而不是mat.transmission_color
                    // 透射也为 delta 分布(pdf = 1-Fr)
                    pdf_bsdf = 1.0 - Fr;
                    f_bsdf = float3(1.0 - Fr, 1.0 - Fr, 1.0 - Fr) / (etaT * etaT);
                } else {
                    rayDir = reflect(-V, normal); // 全反射
                    rayOrigin = hitPos + normal * 0.001;
                    pdf_bsdf = 1.0;
                    f_bsdf = float3(1.0,1.0,1.0);
                }
            }
            // 透明材质的 throughput 更新（delta BSDF）
            float NdotL_delta = abs(dot(N, rayDir));
            throughput *= (f_bsdf * NdotL_delta) / max(pdf_bsdf, 1e-6);
        } 
        // [不透明材质逻辑]
        else {
            float3 F0 = lerp(float3(0.04, 0.04, 0.04), baseColor, mat.metallic);
            float3 F = FresnelSchlick(max(dot(N, V), 0.0), F0);
            float specularProb = lerp(max(F.x, max(F.y, F.z)), 1.0, mat.metallic);
            specularProb = clamp(specularProb, 0.1, 0.9);
            
            pdf_bsdf = 1.0;
            f_bsdf = float3(1.0, 1.0, 1.0);
            float3 F0_bsdf = lerp(float3(0.04, 0.04, 0.04), baseColor, mat.metallic);
            if (Rand01(seed) < specularProb) {
                // 镜面反射/金属
                if (mat.roughness < 0.05) rayDir = reflect(-V, N);
                else rayDir = SampleGGX(N, V, mat.roughness, seed);
                
                rayOrigin = hitPos + N * 0.001;
                
                float NdotL_next = max(dot(N, rayDir), 0.0);
                if (NdotL_next > 0.0) {
                    // 计算 BRDF 和 pdf
                    float3 specF0_col;
                    f_bsdf = CookTorranceBRDF(rayDir, V, N, baseColor, mat.roughness, mat.metallic, specF0_col);
                    pdf_bsdf = CalculateBSDFPdf(rayDir, V, N, mat.roughness, mat.metallic, F0_bsdf, true);
                    // MIS: 估计光源采样（总和）在该方向上的概率
                    float p_light_total = 0.0;
                    for (int k = 0; k < 8; ++k) {
                        AreaLight al2 = area_lights[k];
                        if (al2.strength <= 0.0) continue;
                        float3 lightVec2 = al2.position - hitPos;
                        float distSq2 = dot(lightVec2, lightVec2);
                        float dist2 = sqrt(distSq2);
                        float LdotLn2 = max(dot(-rayDir, al2.direction), 0.0);
                        if (LdotLn2 > 0.0001) {
                            float pdf_area2 = 1.0 / (al2.width * al2.height);
                            float pdf_light_area2 = pdf_area2 * distSq2 / LdotLn2;
                            p_light_total += pdf_light_area2;
                        }
                    }
                    // power heuristic
                    float w_bsdf = 1.0;
                    float denom_bsdf = pdf_bsdf * pdf_bsdf + p_light_total * p_light_total;
                    if (denom_bsdf > 0.0) w_bsdf = (pdf_bsdf * pdf_bsdf) / denom_bsdf;

                    throughput *= (f_bsdf * NdotL_next) / max(pdf_bsdf, 1e-6);
                }
            } else {
                // 漫反射
                rayDir = SampleCosineHemisphere(N, seed);
                rayOrigin = hitPos + N * 0.001;
                // 漫反射采样 - 计算pdf和brdf
                float3 diffuseF0;
                float3 f_bsdf_local = CookTorranceBRDF(rayDir, V, N, baseColor, mat.roughness, mat.metallic, diffuseF0);
                float pdf_bsdf_local = CalculateBSDFPdf(rayDir, V, N, mat.roughness, mat.metallic, F0_bsdf, false);
                // 计算所有面光源对该方向的采样概率总和
                float p_light_total_d = 0.0;
                for (int k = 0; k < 8; ++k) {
                    AreaLight al2 = area_lights[k];
                    if (al2.strength <= 0.0) continue;
                    float3 lightVec2 = al2.position - hitPos;
                    float distSq2 = dot(lightVec2, lightVec2);
                    float dist2 = sqrt(distSq2);
                    float LdotLn2 = max(dot(-rayDir, al2.direction), 0.0);
                    if (LdotLn2 > 0.0001) {
                        float pdf_area2 = 1.0 / (al2.width * al2.height);
                        float pdf_light_area2 = pdf_area2 * distSq2 / LdotLn2;
                        p_light_total_d += pdf_light_area2;
                    }
                }
                float w_bsdf_d = 1.0;
                float denom_d = pdf_bsdf_local * pdf_bsdf_local + p_light_total_d * p_light_total_d;
                if (denom_d > 0.0) w_bsdf_d = (pdf_bsdf_local * pdf_bsdf_local) / denom_d;

                throughput *= (f_bsdf_local * max(dot(N, rayDir), 0.0)) / max(pdf_bsdf_local, 1e-6);
            }
        }

        // 俄罗斯轮盘赌 (Russian Roulette) 终止路径
        if (bounce > 3) {
            float p = max(max(throughput.r, throughput.g), throughput.b);
            if (Rand01(seed) > p) break;
            throughput /= p;
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