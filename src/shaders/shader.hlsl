struct CameraInfo {
  float4x4 screen_to_camera;
  float4x4 camera_to_world;
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
};

struct HoverInfo {
  int hovered_entity_id;
};

RaytracingAccelerationStructure as : register(t0, space0);
RWTexture2D<float4> output : register(u0, space1);
ConstantBuffer<CameraInfo> camera_info : register(b0, space2);
StructuredBuffer<Material> materials : register(t0, space3);
ConstantBuffer<HoverInfo> hover_info : register(b0, space4);
RWTexture2D<int> entity_id_output : register(u0, space5);
RWTexture2D<float4> accumulated_color : register(u0, space6);
RWTexture2D<int> accumulated_samples : register(u0, space7);

struct RayPayload {
	float3 radiance;
	float3 throughput;
	bool hit;
	uint material_idx;
	float3 hit_pos;
	float3 normal;
	float2 barycentrics;
	uint primitive_id;
};

// Debug: shadow visibility boost (用于临时放大 lightVisibilityRGB 以便调试)
static const float SHADOW_DEBUG_BOOST = 1.0;

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

[shader("raygeneration")] void RayGenMain() {
	uint2 dispatchIndex = DispatchRaysIndex().xy;
	int prev_samples = accumulated_samples[dispatchIndex];
	uint seed = (uint)dispatchIndex.x * 1973u + (uint)dispatchIndex.y * 9277u + (uint)prev_samples * 26699u;
	seed = PCGHash(seed);
	seed = PCGHash(seed);
	
	// 生成亚像素抖动 [-0.5, 0.5)
	float jitter_x = Rand01(seed) - 0.5;
	float jitter_y = Rand01(seed) - 0.5;
	float2 pixel_center = (float2)dispatchIndex + float2(0.5 + jitter_x, 0.5 + jitter_y);
	float2 uv = pixel_center / float2(DispatchRaysDimensions().xy);
	uv.y = 1.0 - uv.y;
	float2 d = uv * 2.0 - 1.0;
	
	float4 origin4 = mul(camera_info.camera_to_world, float4(0, 0, 0, 1));
	float4 target = mul(camera_info.screen_to_camera, float4(d, 1, 1));
	float4 direction4 = mul(camera_info.camera_to_world, float4(target.xyz, 0));
	
	float3 rayOrigin0 = origin4.xyz;
	float3 rayDir0 = normalize(direction4.xyz);
	
	const int MAX_BOUNCES = 50; // 增加到50以确保充分的光线弹射
	RayPayload payload;
	payload.radiance = float3(0,0,0);
	payload.throughput = float3(1,1,1);
	payload.hit = false;
	payload.material_idx = 0;
	payload.barycentrics = float2(0, 0);
	payload.primitive_id = 0;
	
	float3 radiance = float3(0,0,0);
	float3 throughput = float3(1,1,1);
	float3 rayOrigin = rayOrigin0;
	float3 rayDir = rayDir0;
	
	for (int bounce = 0; bounce < MAX_BOUNCES; ++bounce) {
		payload.hit = false;
		payload.material_idx = 0;
		payload.hit_pos = float3(0,0,0);
		payload.normal = float3(0,1,0);
		
		RayDesc ray;
		ray.Origin = rayOrigin;
		ray.Direction = rayDir;
		ray.TMin = 0.0001;  // 更小的Ray Epsilon以减少自我遮挡
		ray.TMax = 10000.0;
		
		TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);
		
		if (!payload.hit) {
			// Miss: sample environment / sky
			float3 rayDirNorm = normalize(rayDir);
			float tsky = 0.5 * (rayDirNorm.y + 1.0);
			tsky = smoothstep(0.0, 1.0, tsky);
			// 降低天空亮度避免过曝
			float3 sky = lerp(float3(0.6,0.6,0.6), float3(0.3,0.5,0.8), tsky);
			radiance += throughput * sky;
			break;
		}
		
		// 正确的材质处理
		Material mat = materials[payload.material_idx];
		float3 N = normalize(payload.normal);
		float3 V = normalize(-rayDir);
		
		// 确保法线朝向观察方向（对于非透明材质）
		bool entering = dot(N, V) > 0.0;
		if (!entering && mat.transmission < 0.01) {
			N = -N;
		}
		
		// 定义Ray Epsilon用于法线偏移
		const float RAY_EPSILON = 0.001; // 足够大以避免自我相交
		
		// 透明材质处理
		if (mat.transmission > 0.01) {
			float etaI = 1.0; // 空气
			float etaT = mat.ior; // 材质
			float3 normal = N;
			
			// 判断是进入还是离开介质
			if (!entering) {
				float temp = etaI;
				etaI = etaT;
				etaT = temp;
				normal = -N;
			}
			
			float cosTheta = abs(dot(normal, V));
			float Fr = FresnelDielectric(cosTheta, etaI, etaT);
			
			// 根据Fresnel决定反射还是折射
			float reflectProb = Fr;
			reflectProb = lerp(reflectProb, 1.0, 1.0 - mat.transmission);
			
			float randChoice = Rand01(seed);
			if (randChoice < reflectProb) {
				// 反射 - 不改变颜色，只反射
				rayDir = reflect(-V, normal);
				rayOrigin = payload.hit_pos + normal * RAY_EPSILON; // 使用定义的Ray Epsilon
				// 反射不吸收颜色
			} else {
				// 折射
				float3 refracted;
				float eta = etaI / etaT;
				if (Refract(-V, normal, eta, refracted)) {
					rayDir = normalize(refracted);
					rayOrigin = payload.hit_pos - normal * RAY_EPSILON; // 使用定义的Ray Epsilon
					// 光线穿过玻璃时应用传输颜色（有色玻璃应使用 transmission_color）
					throughput *= mat.transmission_color * mat.transmission;
				} else {
					// 全反射
					rayDir = reflect(-V, normal);
					rayOrigin = payload.hit_pos + normal * RAY_EPSILON; // 使用定义的Ray Epsilon
				}
			}
			continue; // 跳过常规的镜面/漫反射处理
		}
		
		// 计算Fresnel（非透明材质）
		float3 F0 = lerp(float3(0.04,0.04,0.04), mat.base_color, mat.metallic);
		float cosTheta = max(dot(N, V), 0.0);
		float3 F = FresnelSchlick(cosTheta, F0);
		
		// 选择镜面或漫反射分支
		float specularProb = max(max(F.x, F.y), F.z);
		specularProb = lerp(specularProb, 1.0, mat.metallic * 0.9); // 金属偏向镜面
		specularProb = clamp(specularProb, 0.1, 0.95); // 避免极端值
		
		float rselect = Rand01(seed);
		
		if (rselect < specularProb) {
			// 镜面反射分支
			if (mat.roughness < 0.05) {
				// 完美镜面
				rayDir = reflect(-V, N);
			} else {
				// 粗糙镜面(GGX采样)
				rayDir = SampleGGX(N, V, mat.roughness, seed);
			}
			
			rayOrigin = payload.hit_pos + N * RAY_EPSILON; // 使用定义的Ray Epsilon
			
			// 正确的能量补偿
			float NdotL = max(dot(N, rayDir), 0.0);
			if (NdotL > 0.001) {
				throughput *= F * NdotL / specularProb;
			} else {
				break; // 终止无效路径
			}
		} else {
			// 漫反射分支
			rayDir = SampleCosineHemisphere(N, seed);
			rayOrigin = payload.hit_pos + N * RAY_EPSILON; // 使用定义的Ray Epsilon
			
			// Lambert BRDF: baseColor/π, pdf = cosθ/π, 相消后剩baseColor
			float3 diffuseAlbedo = mat.base_color * (1.0 - mat.metallic);
			throughput *= diffuseAlbedo * (1.0 - F) / (1.0 - specularProb);
		}
		
		// Alpha Shadow 可见性检查（直接光源计算）
		// 检查是否直接可见到光源
		if (bounce == 0 && payload.hit) {
			// 仅在第一次反弹时计算以提高性能
			float3 lightDir = normalize(float3(1.0, 2.0, 1.0));
			float3 lightVisibilityRGB = TraceAlphaShadowRGB(payload.hit_pos + N * RAY_EPSILON,
															lightDir,
															100.0,
															seed);
			// 临时放大用于调试并限制在[0,1]
			lightVisibilityRGB *= SHADOW_DEBUG_BOOST;
			lightVisibilityRGB = clamp(lightVisibilityRGB, 0.0, 1.0);

			// 计算漫反射直接照明（光源假设为白光，可扩展为光源颜色）
			float NdotL = max(dot(N, lightDir), 0.0);
			float3 lightColor = float3(1.0, 1.0, 1.0);
			float3 directLight = mat.base_color * NdotL * lightColor * lightVisibilityRGB * 0.8;
			if (NdotL > 0.001) {
				radiance += throughput * directLight;
			}
		}
		
		// Russian Roulette
		if (bounce >= 2) {
			float p = max(max(throughput.x, throughput.y), throughput.z);
			p = min(p, 0.95);
			if (Rand01(seed) > p) { break; }
			throughput /= max(p, 0.001);
		}
	}
	
	// 累积并输出平均值
	float4 prev_color = accumulated_color[dispatchIndex];
	int prev_samps = prev_samples;
	float4 new_sum = prev_color + float4(radiance, 1);
	int new_count = prev_samps + 1;
	accumulated_color[dispatchIndex] = new_sum;
	accumulated_samples[dispatchIndex] = new_count;
	
	float4 averaged = new_sum / max(1, new_count);
	output[dispatchIndex] = averaged;
	entity_id_output[dispatchIndex] = payload.hit ? (int)payload.material_idx : -1;
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
	
	// 暂时回到更简单但更正确的几何法线计算方法
	// 使用命中点位置来推断法线，但针对不同几何体类型进行优化
	
	float3 worldPos = payload.hit_pos;
	float3 objectPos = mul(WorldToObject3x4(), float4(worldPos, 1.0)).xyz;
	float3 objectNormal;
	
	// 根据实体ID来判断几何体类型
	uint entity_id = InstanceID();
	
	if (entity_id == 0) {
		// 地面（第一个实体）- 始终使用向上的法线
		objectNormal = float3(0, 1, 0);
	}
	else {
		// 对于八面体和立方体，使用更智能的法线计算
		// 计算到物体中心的方向作为法线的起点
		objectNormal = normalize(objectPos);
		
		// 对于立方体（最后一个实体），使用面法线
		if (entity_id == 3) { // 蓝色立方体
			float3 absPos = abs(objectPos);
			float maxComp = max(max(absPos.x, absPos.y), absPos.z);
			
			if (abs(absPos.x - maxComp) < 0.01) {
				objectNormal = float3(sign(objectPos.x), 0, 0);
			} else if (abs(absPos.y - maxComp) < 0.01) {
				objectNormal = float3(0, sign(objectPos.y), 0);
			} else if (abs(absPos.z - maxComp) < 0.01) {
				objectNormal = float3(0, 0, sign(objectPos.z));
			}
		}
	}
	
	// 转换到世界空间
	float3x3 objectToWorld = (float3x3)ObjectToWorld3x4();
	payload.normal = normalize(mul(objectToWorld, objectNormal));
	
	// 确保法线朝向光线来源
	if (dot(payload.normal, -WorldRayDirection()) < 0) {
		payload.normal = -payload.normal;
	}
}