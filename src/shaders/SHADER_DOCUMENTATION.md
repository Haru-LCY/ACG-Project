# Shader 文件文档




第四个问题：BSDF 里面的数值保护关闭，现在的渲染出小白点问题到底在哪？
第五个问题：lighting 的MAX_BOUNCES=6 多少次 NUM_LIGHT_SAMPLES 仍然数值保护。
第六个问题：Skybox 使用简化的 Blinn-Phong 镜面反射，而不是 Principled BSDF？
第七个问题：运动模糊 Apply Motion Blur 应该在 motion blur 这里实现。
第八个问题：暂时不需要快门形状，要不要删除。
第九个问题：只需要做平移模糊，不需要其他内容。
第十个问题：为啥 motion blur 在这里实现啊，其次是 max_bounce 怎么 =8 和前面 lighting 也没匹配上啊。也要删除相关数值保护。(重构 raytracing 函数)
第十二个问题：shader.hlsl 太长，数值保护过多，逻辑复杂。

本文档详细说明光线追踪渲染管线中所有 shader 文件的功能、函数作用以及优化建议。

---

## 目录

1. [common.hlsl](#commonhlsl) - 通用结构体和资源声明
2. [rng.hlsl](#rnghlsl) - 随机数生成
3. [geometry.hlsl](#geometryhlsl) - 几何计算工具
4. [bsdf.hlsl](#bsdfhlsl) - BSDF 材质模型实现
5. [lighting.hlsl](#lightinghlsl) - 光源计算
6. [skybox.hlsl](#skyboxhlsl) - 天空盒和环境光照
7. [raygen.hlsl](#raygenhlsl) - 光线生成
8. [msaa.hlsl](#msaahlsl) - 多重采样抗锯齿
9. [motion_blur.hlsl](#motion_blurhlsl) - 运动模糊
10. [raytracing.hlsl](#raytracinghlsl) - 路径追踪核心逻辑
11. [shader.hlsl](#shaderhlsl) - 主着色器入口
12. [disney.glsl](#disneyglsl) - Disney BSDF (GLSL版本，可能未使用)

---

## common.hlsl

**作用**: 定义所有 shader 共用的数据结构、常量和资源绑定。

### 结构体

- **CameraInfo**: 相机参数（变换矩阵、光圈、焦距、曝光、MSAA模式、运动模糊参数等）
- **Material**: Principled BSDF 材质参数（颜色、粗糙度、金属度、各向异性、清漆层等）
- **PointLight**: 点光源（位置、强度、颜色、半径）
- **AreaLight**: 面光源（位置、尺寸、方向、颜色、强度）
- **RayPayload**: 光线追踪载荷（辐射度、throughput、击中信息、材质索引、UV坐标等）
- **SkyboxInfo**: 天空盒信息（环境贴图、程序化天空颜色、太阳参数等）
- **HoverInfo**: 鼠标悬停信息

### 资源绑定

- `as`: 光线追踪加速结构
- `output`: 输出纹理
- `camera_info`: 相机常量缓冲区
- `materials`: 材质数组
- `point_lights`: 点光源数组
- `area_lights`: 面光源数组
- `textures`: 纹理数组（最多16个）
- `entity_velocities`: 实体速度数组（用于运动模糊）
- `skybox_info`: 天空盒常量缓冲区
- `environment_map`: HDR 环境贴图

### 优化建议

- **无函数，仅定义**: 此文件只包含数据定义，无需优化
- **建议**: 可以考虑将某些不常用的结构体字段合并以减少内存占用

---

## rng.hlsl

**作用**: 提供高质量的随机数生成器，用于蒙特卡洛采样。

### 函数列表

#### `PCGHash(inout uint state) -> uint`
- **功能**: PCG 哈希函数，生成伪随机数
- **用途**: 随机数生成的核心函数
- **优化建议**: 
  - 当前实现已经相当高效
  - 可以考虑使用硬件随机数生成器（如果GPU支持）

#### `Rand01(inout uint state) -> float`
- **功能**: 生成 [0, 1) 范围的随机浮点数
- **用途**: 所有需要随机采样的地方
- **优化建议**: 无

#### `SampleUnitDisk(inout uint seed) -> float2`
- **功能**: 在单位圆盘内均匀采样一个点
- **用途**: 景深效果中的光圈采样
- **优化建议**: 
  - 当前使用极坐标采样，分布均匀
  - 可以考虑使用分层采样（Stratified Sampling）提高收敛速度

---

## geometry.hlsl

**作用**: 提供几何计算工具函数，包括法线计算和UV坐标计算。

### 函数列表

#### `ComputeBoxFaceNormal(float3 objectPos) -> float3`
- **功能**: 计算立方体的面法线（用于墙壁和玻璃立方体）
- **用途**: 为立方体几何体提供正确的平面法线
- **问题**: 
  - 使用硬编码的阈值 `0.01` 判断最大分量，可能在边界处不稳定
- **优化建议**: 
  - 使用更稳定的方法：直接找到最大分量的索引，避免浮点比较
  - 简化代码：`if (absPos.x >= max(absPos.y, absPos.z)) return sign(objectPos.x) * float3(1,0,0);`

#### `ComputeOctahedronNormal(float3 objectPos) -> float3`
- **功能**: 计算八面体的平滑法线（归一化位置向量）
- **用途**: 为八面体提供平滑的法线
- **优化建议**: 无，实现简洁

#### `ComputeGeometryNormal(uint entity_id, float3 objectPos) -> float3`
- **功能**: 根据实体ID计算几何法线
- **用途**: 统一接口，根据实体类型选择法线计算方法
- **问题**: 
  - 硬编码实体ID范围（0-4为墙壁，5-6为八面体，7为玻璃立方体）
- **优化建议**: 
  - 将实体类型信息存储在材质或实例数据中，而不是硬编码ID范围
  - 使用枚举或标志位来标识几何类型

#### `ComputeBoxUV(float3 objectPos, float3 worldNormal) -> float2`
- **功能**: 计算立方体的UV坐标（平面映射）
- **用途**: 为立方体提供纹理坐标
- **问题**: 
  - 代码冗长，有大量重复的UV计算逻辑
  - `scale` 变量始终为1，无实际作用
- **优化建议**: 
  - 提取公共的UV计算逻辑到辅助函数
  - 移除无用的 `scale` 变量
  - 考虑使用更简洁的立方体贴图映射方法

#### `ComputeOctahedronUV(float3 objectPos) -> float2`
- **功能**: 计算八面体的UV坐标（球面映射）
- **用途**: 为八面体提供纹理坐标
- **优化建议**: 无，实现简洁

#### `ComputeGeometryUV(uint entity_id, float3 objectPos, float3 worldNormal) -> float2`
- **功能**: 根据实体ID计算UV坐标
- **用途**: 统一接口，根据实体类型选择UV计算方法
- **优化建议**: 同 `ComputeGeometryNormal`，避免硬编码ID范围

---

## bsdf.hlsl

**作用**: 实现 Principled BSDF（基于物理的材质模型），包括漫反射、镜面反射、清漆层、各向异性等。

### 函数列表

#### MIS (Multiple Importance Sampling) 函数

##### `PowerHeuristic(float pdf_a, float pdf_b) -> float`
- **功能**: Power heuristic (β=2) 用于 MIS 权重计算
- **用途**: 结合光源采样和BSDF采样时计算权重
- **优化建议**: 无

##### `BalanceHeuristic(float pdf_a, float pdf_b) -> float`
- **功能**: Balance heuristic 用于 MIS 权重计算
- **用途**: 结合光源采样和BSDF采样时计算权重
- **优化建议**: 无

#### 基础采样函数

##### `SampleCosineHemisphere(float3 n, inout uint seed, out float pdf) -> float3`
- **功能**: Lambertian 漫反射的余弦加权半球采样
- **用途**: 生成漫反射方向
- **优化建议**: 无，实现标准

#### 材质颜色函数

##### `GetMaterialBaseColor(Material mat, float2 uv) -> float3`
- **功能**: 获取材质的基础颜色（考虑纹理）
- **用途**: 统一获取材质颜色，支持纹理采样
- **问题**: 
  - 硬编码纹理数量上限（16）
- **优化建议**: 
  - 使用动态纹理数组大小（如果HLSL支持）
  - 添加纹理边界检查的错误处理

#### Fresnel 和折射函数

##### `FresnelSchlick(float cosTheta, float3 F0) -> float3`
- **功能**: Schlick Fresnel 近似
- **用途**: 计算菲涅尔反射系数
- **优化建议**: 无

##### `Refract(float3 I, float3 N, float eta, out float3 refracted) -> bool`
- **功能**: Snell's Law 折射计算
- **用途**: 计算折射方向，处理全反射情况
- **优化建议**: 无

##### `FresnelDielectric(float cosThetaI, float etaI, float etaT) -> float`
- **功能**: 介质 Fresnel（用于透明材质）
- **用途**: 计算透明材质的菲涅尔系数
- **问题**: 
  - 代码较长，包含大量边界情况处理
- **优化建议**: 
  - 可以简化为使用 Schlick 近似（如果精度要求不高）
  - 提取公共计算到局部变量

#### 辅助计算函数

##### `BuildOrthonormalBasis(float3 N, out float3 T, out float3 B)`
- **功能**: 从法线构建正交基（切线和副切线）
- **用途**: 各向异性BSDF需要切空间
- **优化建议**: 无

##### `ComputeAnisotropicAlpha(float roughness, float anisotropic, out float alpha_x, out float alpha_y)`
- **功能**: 计算各向异性 alpha 值
- **用途**: 减少重复计算
- **优化建议**: 无

##### `ComputeSpecularColor(Material mat, float3 baseColor, out float3 spec_color, out float3 F0)`
- **功能**: 计算镜面反射颜色和 F0
- **用途**: 减少重复计算
- **优化建议**: 无

##### `ComputeLobeWeights(float3 F, float3 kD, float clearcoat, out float diffuse_weight, out float specular_weight, out float clearcoat_weight)`
- **功能**: 计算各 lobe 的权重（用于重要性采样）
- **用途**: BSDF 采样时选择采样哪个 lobe
- **优化建议**: 无

#### GGX 微表面模型函数

##### `GGX_D(float3 H, float3 N, float3 T, float3 B, float roughness, float anisotropic) -> float`
- **功能**: GGX 分布函数（支持各向异性）
- **用途**: 计算微表面法线分布
- **问题**: 
  - 包含大量数值稳定性保护代码（MIN_V2, MAX_W2, MAX_D）
  - 这些保护可能掩盖了真正的数值问题
- **优化建议**: 
  - 检查输入参数的有效性（roughness 是否在合理范围）
  - 考虑使用更稳定的 GGX 实现（如使用 `saturate` 和更小的 epsilon）
  - 如果数值问题持续存在，检查调用方是否正确传递参数

##### `GGX_G1(float3 V, float3 N, float3 T, float3 B, float roughness, float anisotropic) -> float`
- **功能**: GGX 几何项（Smith G1）
- **用途**: 计算自遮挡
- **优化建议**: 无

##### `GGX_G(float3 V, float3 L, float3 N, float3 T, float3 B, float roughness, float anisotropic) -> float`
- **功能**: GGX 几何项（Smith G = G1(V) * G1(L)）
- **用途**: 计算双向遮挡
- **优化建议**: 无

#### GGX 采样函数

##### `SampleGGX_Internal(float3 N, float3 V, float3 T, float3 B, float roughness, float anisotropic, float anisotropic_rotation, inout uint seed, out float pdf) -> float3`
- **功能**: GGX 分布采样（内部版本，接受预计算的 T, B）
- **用途**: 生成镜面反射方向
- **问题**: 
  - 代码较长，包含各向异性旋转计算
- **优化建议**: 
  - 如果 `anisotropic_rotation` 很少使用，可以将其设为可选参数
  - 提取旋转计算到单独函数

##### `SampleGGX(float3 N, float3 V, float roughness, float anisotropic, float anisotropic_rotation, inout uint seed, out float pdf) -> float3`
- **功能**: GGX 分布采样（外部接口）
- **用途**: 保持兼容性的外部接口
- **优化建议**: 无

#### Sheen 和 Clearcoat 函数

##### `EvaluateSheen(float3 V, float3 L, float3 N, float3 base_color, float sheen, float sheen_tint) -> float3`
- **功能**: Sheen BRDF 评估（Estevez & Kulla）
- **用途**: 计算织物的绒毛效果
- **优化建议**: 无

##### `EvaluateClearcoat(float3 V, float3 L, float3 N, float clearcoat, float clearcoat_roughness, out float pdf) -> float3`
- **功能**: Clearcoat BRDF 评估
- **用途**: 计算清漆层（如汽车漆）
- **优化建议**: 无

##### `SampleClearcoat(float3 N, float3 V, float clearcoat_roughness, inout uint seed, out float pdf) -> float3`
- **功能**: Clearcoat lobe 采样
- **用途**: 生成清漆层反射方向
- **优化建议**: 无

#### Principled BSDF 主函数

##### `EvaluatePrincipledBSDF(Material mat, float3 V, float3 L, float3 N, float2 uv, out float pdf) -> float3`
- **功能**: Principled BSDF 评估（给定入射和出射方向）
- **用途**: 计算给定方向的BRDF值
- **问题**: 
  - 包含大量数值保护代码（MIN_DENOM, MAX_SPECULAR）
  - 代码较长，包含多个 lobe 的计算
- **优化建议**: 
  - 如果某些 lobe（如 sheen, clearcoat）很少使用，可以添加早期退出
  - 提取每个 lobe 的计算到单独函数（如果可读性更重要）
  - 检查数值保护是否真的必要，可能问题出在调用方

##### `SamplePrincipledBSDF(Material mat, float3 V, float3 N, float2 uv, inout uint seed, out float pdf, out float3 weight) -> float3`
- **功能**: Principled BSDF 采样（重要性采样）
- **用途**: 生成新的光线方向
- **问题**: 
  - 包含大量数值保护代码（MAX_WEIGHT）
  - 代码较长，包含 lobe 选择和权重计算
- **优化建议**: 
  - 如果 weight 限制频繁触发，检查 `EvaluatePrincipledBSDF` 的返回值是否异常
  - 考虑使用更稳定的 PDF 计算方法
  - 简化 lobe 选择逻辑（如果某些 lobe 很少使用）

---

## lighting.hlsl

**作用**: 计算光源的直接光照贡献，包括点光源和面光源，支持软阴影和透明材质。

### 函数列表

#### `TraceAlphaShadowRGB(float3 rayOrigin, float3 rayDirection, float maxDistance, inout uint seed) -> float3`
- **功能**: Alpha shadow 阴影射线追踪（支持有色透射和 Beer-Lambert 衰减）
- **用途**: 计算光源到表面的可见度，支持透明材质
- **问题**: 
  - 硬编码最大弹射次数（MAX_BOUNCES = 6）
  - 透明材质的透射计算可能不够精确
- **优化建议**: 
  - 将 MAX_BOUNCES 设为可配置参数
  - 对于完全透明的材质，可以考虑提前终止
  - 改进 Beer-Lambert 衰减计算（当前使用简化版本）

#### `ComputeAreaLightContribution(float3 hitPos, float3 normal, float3 viewDir, Material material, float2 uv, AreaLight light, inout uint seed) -> float3`
- **功能**: 计算面光源的直接光照贡献（使用 Principled BSDF）
- **用途**: 面光源的直接光照计算，支持 MIS
- **问题**: 
  - 硬编码采样数量（NUM_LIGHT_SAMPLES = 1）
  - 代码较长，包含大量几何计算
- **优化建议**: 
  - 将采样数量设为可配置参数
  - 提取几何计算到辅助函数
  - 如果面光源很少使用，可以考虑简化实现

#### `ComputePointLightContribution(float3 hitPos, float3 normal, float3 viewDir, Material material, float2 uv, PointLight light, inout uint seed) -> float3`
- **功能**: 计算点光源的直接光照贡献（使用 Principled BSDF）
- **用途**: 点光源的直接光照计算
- **问题**: 
  - 包含大量数值保护代码（MIN_LIGHT_DISTANCE, MAX_ATTENUATION, MAX_RADIANCE_PER_LIGHT）
  - 距离衰减计算复杂，包含平滑因子
- **优化建议**: 
  - 简化距离衰减计算：如果光源半径很小，使用标准平方反比定律
  - 检查数值保护是否真的必要，可能问题出在光源参数设置
  - 如果光源半径始终为0，可以移除相关代码

---

## skybox.hlsl

**作用**: 提供天空盒和环境光照功能，支持 HDR 环境贴图和程序化天空。

### 函数列表

#### 环境贴图采样函数

##### `DirectionToEquirectangularUV(float3 direction) -> float2`
- **功能**: 将方向向量转换为等距柱状投影 UV 坐标
- **用途**: 环境贴图采样
- **优化建议**: 无

##### `EquirectangularUVToDirection(float2 uv) -> float3`
- **功能**: 从等距柱状投影 UV 坐标转换回方向向量
- **用途**: 环境贴图重要性采样（如果实现）
- **优化建议**: 无

##### `SampleEnvironmentMap(float3 direction) -> float3`
- **功能**: 采样 HDR 环境贴图
- **用途**: 环境光照和天空盒
- **优化建议**: 无

##### `SampleEnvironmentMapLOD(float3 direction, float lod) -> float3`
- **功能**: 带 LOD 的环境贴图采样（用于模糊反射）
- **用途**: 根据粗糙度选择不同模糊度的环境贴图
- **优化建议**: 无

#### 程序化天空函数

##### `GetProceduralSky(float3 direction) -> float3`
- **功能**: 程序化天空（作为后备或调试）
- **用途**: 当没有环境贴图时使用
- **优化建议**: 无

#### 环境光照计算函数

##### `GetEnvironmentIrradiance(float3 normal) -> float3`
- **功能**: 计算漫反射环境光照（粗糙的半球采样近似）
- **用途**: 环境漫反射
- **问题**: 
  - 使用固定 LOD (4.0)，可能不够精确
- **优化建议**: 
  - 如果性能允许，使用重要性采样计算更精确的辐照度
  - 或者预计算辐照度贴图

##### `GetEnvironmentReflection(float3 reflectionDir, float roughness) -> float3`
- **功能**: 计算镜面反射环境光照
- **用途**: 环境镜面反射
- **优化建议**: 无

#### 重要性采样辅助函数

##### `CosineSampleHemisphere(float u1, float u2, float3 normal) -> float3`
- **功能**: 生成余弦加权半球采样方向（用于漫反射 IBL）
- **用途**: 环境光照重要性采样
- **优化建议**: 无

##### `ImportanceSampleGGX(float u1, float u2, float3 normal, float roughness) -> float3`
- **功能**: GGX 重要性采样（用于镜面 IBL）
- **用途**: 环境光照重要性采样
- **优化建议**: 无

#### 环境光照主函数

##### `ComputeEnvironmentLighting(float3 hitPos, float3 normal, float3 viewDir, Material material, inout uint seed) -> float3`
- **功能**: 计算完整的环境光照贡献（IBL）
- **用途**: 环境光照计算
- **问题**: 
  - 使用简化的环境 BRDF 近似（`envBRDF`）
- **优化建议**: 
  - 如果精度要求高，使用预计算的环境 BRDF 查找表
  - 或者使用更精确的近似公式

#### 太阳/方向光函数

##### `GetSunDirection() -> float3`
- **功能**: 获取太阳方向
- **用途**: 太阳光照计算
- **优化建议**: 无

##### `GetSunColor() -> float3`
- **功能**: 获取太阳颜色
- **用途**: 太阳光照计算
- **优化建议**: 无

##### `ComputeSunLighting(float3 hitPos, float3 normal, float3 viewDir, Material material, inout uint seed) -> float3`
- **功能**: 计算太阳直接光照贡献
- **用途**: 太阳光照计算
- **问题**: 
  - 使用简化的 Blinn-Phong 镜面反射，而不是 Principled BSDF
  - 没有阴影检测（注释中提到但未实现）
- **优化建议**: 
  - 使用 Principled BSDF 评估（与点光源和面光源一致）
  - 实现阴影检测（调用 `TraceAlphaShadowRGB`）

---

## raygen.hlsl

**作用**: 提供相机光线生成函数，支持景深效果。

### 函数列表

#### `GenerateCameraRay(uint2 dispatchIndex, float2 jitter, out float3 rayOrigin, out float3 rayDir)`
- **功能**: 生成相机光线（无景深）
- **用途**: 基础相机光线生成
- **优化建议**: 无

#### `GenerateCameraRayWithDOF(uint2 dispatchIndex, float2 jitter, inout uint seed, out float3 rayOrigin, out float3 rayDir)`
- **功能**: 生成带景深效果的相机光线
- **用途**: 景深（Depth of Field）效果
- **问题**: 
  - 如果光圈很小（接近0），仍然会进行不必要的计算
- **优化建议**: 
  - 早期退出已经实现，但可以进一步优化：如果 `aperture <= 0.0001`，直接调用 `GenerateCameraRay`

#### `GeneratePickRay(uint2 dispatchIndex, out float3 rayOrigin, out float3 rayDir)`
- **功能**: 生成用于实体选择的光线（无抖动，无景深）
- **用途**: 鼠标拾取
- **优化建议**: 无

---

## msaa.hlsl

**作用**: 提供多重采样抗锯齿（MSAA）功能，包括标准 MSAA 模式和高级采样方法。

### 函数列表

#### MSAA 采样函数

##### `GetMSAASampleCount(int msaa_mode) -> int`
- **功能**: 获取指定 MSAA 模式的采样数量
- **用途**: 确定需要多少次采样
- **优化建议**: 无

##### `GetMSAASampleOffset(int msaa_mode, int sample_idx, inout uint seed) -> float2`
- **功能**: 获取 MSAA 采样位置
- **用途**: 获取子像素偏移量
- **优化建议**: 无

#### 分层采样函数

##### `GetStratifiedSampleOffset(int sample_idx, int total_samples, inout uint seed) -> float2`
- **功能**: 获取分层采样偏移
- **用途**: 更均匀的随机采样分布
- **优化建议**: 无

#### 低差异序列函数

##### `GetR2SampleOffset(int sample_idx) -> float2`
- **功能**: 获取 R2 序列采样偏移
- **用途**: 低差异序列采样
- **优化建议**: 无

##### `HaltonSequence(int index, int base) -> float`
- **功能**: Halton 序列生成
- **用途**: 低差异序列采样
- **优化建议**: 无

##### `GetHaltonSampleOffset(int sample_idx) -> float2`
- **功能**: 获取 Halton 序列采样偏移
- **用途**: 低差异序列采样
- **优化建议**: 无

#### 高级 MSAA 函数

##### `GetTemporalMSAASampleOffset(int msaa_mode, int sample_idx, int frame_idx, inout uint seed) -> float2`
- **功能**: 组合模式：标准 MSAA + 时间累积
- **用途**: 时间累积抗锯齿
- **优化建议**: 无

#### 实用工具函数

##### `GetMSAASampleWeight(int msaa_mode, int sample_idx) -> float`
- **功能**: 计算采样权重（用于加权平均）
- **用途**: 某些 MSAA 模式可能需要非均匀权重
- **问题**: 
  - 当前始终返回 1.0，函数无实际作用
- **优化建议**: 
  - 如果不需要非均匀权重，可以移除此函数
  - 或者实现实际的权重计算（如果某些模式需要）

##### `IsMSAAEnabled(int msaa_mode) -> bool`
- **功能**: 检查是否应该使用 MSAA
- **用途**: 条件判断
- **优化建议**: 无

---

## motion_blur.hlsl

**作用**: 实现运动模糊效果，支持相机运动模糊、物体运动模糊、径向模糊和方向性模糊。

### 函数列表

#### 时间采样函数

##### `SampleTime(inout uint seed) -> float`
- **功能**: 生成随机时间采样点
- **用途**: 时间域采样
- **优化建议**: 无

##### `SampleTimeStratified(int sample_index, int total_samples, inout uint seed) -> float`
- **功能**: 生成分层时间采样点
- **用途**: 更均匀的时间分布
- **优化建议**: 无

#### 相机运动模糊函数

##### `InterpolateCameraTransform(float4x4 prev_camera_to_world, float4x4 curr_camera_to_world, float t) -> float4x4`
- **功能**: 计算相机运动模糊偏移（通过插值相机变换矩阵）
- **用途**: 相机运动模糊
- **问题**: 
  - 使用简单的线性插值，对于大幅度旋转可能不够精确
  - 函数签名需要前一帧的相机矩阵，但当前实现中可能没有提供
- **优化建议**: 
  - 如果前一帧矩阵不可用，使用简化的抖动方法（如当前 `ApplyMotionBlur` 中的实现）
  - 对于旋转，使用四元数插值（如果性能允许）

#### 径向和方向性模糊函数

##### `ComputeRadialBlurOffset(float2 uv, float2 center, float intensity, float t) -> float2`
- **功能**: 计算径向模糊的光线方向偏移
- **用途**: 径向运动模糊
- **优化建议**: 无

##### `ComputeDirectionalBlurOffset(float2 direction, float intensity, float t) -> float2`
- **功能**: 计算方向性模糊的UV偏移
- **用途**: 方向性运动模糊
- **优化建议**: 无

#### 物体运动模糊函数

##### `GetEntityVelocity(uint entity_id) -> float3`
- **功能**: 获取实体的速度向量
- **用途**: 物体运动模糊
- **问题**: 
  - 硬编码最大实体数量（MAX_ENTITIES = 256）
- **优化建议**: 
  - 使用动态数组大小（如果HLSL支持）
  - 或者从常量缓冲区读取最大实体数量

##### `ComputeObjectMotionBlurPosition(float3 hit_pos, uint entity_id, float t) -> float3`
- **功能**: 计算物体运动模糊的击中点偏移
- **用途**: 物体运动模糊
- **优化建议**: 无

##### `ComputeMotionVector(float3 prev_world_pos, float3 curr_world_pos, float4x4 view_proj, float4x4 prev_view_proj) -> float2`
- **功能**: 计算运动向量（用于后处理运动模糊）
- **用途**: 后处理运动模糊
- **问题**: 
  - 需要前一帧的位置和变换矩阵，当前实现中可能没有提供
- **优化建议**: 
  - 如果前一帧数据不可用，此函数无法使用
  - 或者简化实现，使用速度向量近似

#### 主要运动模糊函数

##### `ApplyMotionBlur(inout float3 ray_origin, inout float3 ray_dir, float2 uv, float shutter_time, float intensity, int mode, inout uint seed)`
- **功能**: 应用运动模糊到光线生成
- **用途**: 相机/径向/方向运动模糊
- **问题**: 
  - `MOTION_BLUR_MODE_OBJECT` 分支为空，实际物体运动模糊在 `raytracing.hlsl` 中实现
- **优化建议**: 
  - 移除 `MOTION_BLUR_MODE_OBJECT` 分支（物体运动模糊在路径追踪中处理）
  - 或者添加注释说明物体运动模糊在别处处理

#### 光线时间抖动函数

##### `GetRayTime(int sample_index, int total_samples, inout uint seed) -> float`
- **功能**: 为光线添加时间信息
- **用途**: 运动物体的模糊
- **优化建议**: 无

#### 快门形状函数

##### `BoxShutter(float t) -> float`
- **功能**: 盒形快门（均匀分布）
- **用途**: 快门形状权重
- **问题**: 
  - 当前未使用
- **优化建议**: 
  - 如果不需要快门形状，可以移除这些函数
  - 或者实现实际的使用（在采样时应用权重）

##### `TriangleShutter(float t) -> float`
- **功能**: 三角形快门（中间权重最大）
- **用途**: 快门形状权重
- **优化建议**: 同 `BoxShutter`

##### `GaussianShutter(float t) -> float`
- **功能**: 高斯快门（更平滑的过渡）
- **用途**: 快门形状权重
- **优化建议**: 同 `BoxShutter`

#### 简化的运动模糊光线生成函数

##### `GenerateCameraRayWithMotionBlur(uint2 dispatch_index, float2 jitter, float motion_blur_intensity, float2 motion_blur_direction, inout uint seed, out float3 ray_origin, out float3 ray_dir)`
- **功能**: 生成带运动模糊的相机光线（简化版本）
- **用途**: 运动模糊光线生成
- **问题**: 
  - 与 `ApplyMotionBlur` 功能重复
- **优化建议**: 
  - 统一使用 `ApplyMotionBlur`，移除此函数
  - 或者保留此函数作为更高级的接口

#### 旋转和缩放模糊函数

##### `ComputeRotationalBlurOffset(float2 uv, float2 center, float angular_velocity, float t) -> float2`
- **功能**: 计算旋转模糊的偏移
- **用途**: 旋转运动模糊
- **问题**: 
  - 当前未使用
- **优化建议**: 
  - 如果不需要旋转模糊，可以移除
  - 或者添加到 `ApplyMotionBlur` 的支持模式中

##### `ComputeZoomBlurOffset(float2 uv, float2 center, float scale_factor, float t) -> float2`
- **功能**: 计算缩放模糊的偏移（dolly zoom效果）
- **用途**: 缩放运动模糊
- **问题**: 
  - 当前未使用
- **优化建议**: 
  - 如果不需要缩放模糊，可以移除
  - 或者添加到 `ApplyMotionBlur` 的支持模式中

---

## raytracing.hlsl

**作用**: 实现路径追踪核心逻辑，包括直接光照、间接光照、俄罗斯轮盘赌终止等。

### 函数列表

#### Tone Mapping 函数

##### `ACESFilm(float3 x) -> float3`
- **功能**: ACES Tone Mapping（解决过曝/刺眼问题）
- **用途**: HDR 到 LDR 的色调映射
- **优化建议**: 无

#### 基础追踪函数

##### `TraceRaySimple(float3 rayOrigin, float3 rayDir, float tMin, float tMax, inout RayPayload payload) -> bool`
- **功能**: 简单的光线追踪函数，直接使用硬件加速的 TraceRay
- **用途**: 基础光线追踪
- **优化建议**: 无

#### 路径追踪函数

##### `TracePathWithObjectMotionBlur(float3 rayOrigin, float3 rayDir, float motion_time, inout uint seed) -> float3`
- **功能**: 执行路径追踪（支持物体运动模糊）
- **用途**: 主要的路径追踪函数
- **问题**: 
  - 代码非常长（200+ 行），包含大量逻辑
  - 硬编码最大弹射次数（MAX_BOUNCES = 8）
  - 包含大量数值保护代码
  - 物体运动模糊逻辑只在第一次弹射时应用
- **优化建议**: 
  - **重构建议**: 将路径追踪拆分为多个函数：
    - `ComputeDirectLighting()`: 直接光照计算
    - `SampleIndirectLighting()`: 间接光照采样
    - `HandleTransmission()`: 透明材质处理
    - `HandleOpaqueMaterial()`: 不透明材质处理
    - `ApplyRussianRoulette()`: 俄罗斯轮盘赌
  - **简化建议**: 
    - 将 MAX_BOUNCES 设为可配置参数
    - 如果物体运动模糊很少使用，可以将其设为可选功能
    - 检查数值保护是否真的必要，可能问题出在材质参数或光源设置
  - **性能优化**: 
    - 对于自发光材质，可以提前终止（已实现）
    - 对于完全透明的材质，可以考虑跳过某些计算

##### `TracePath(float3 rayOrigin, float3 rayDir, inout uint seed) -> float3`
- **功能**: 标准路径追踪入口函数
- **用途**: 不启用物体运动模糊时的路径追踪
- **优化建议**: 无

##### `TracePathObjectMotionBlur(float3 rayOrigin, float3 rayDir, inout uint seed) -> float3`
- **功能**: 物体运动模糊的屏幕空间实现
- **用途**: 物体运动模糊
- **问题**: 
  - 代码非常长（100+ 行），包含复杂的逻辑
  - 使用多次光线追踪来模拟运动模糊，性能开销大
  - 硬编码速度探针数量（NUM_VELOCITY_PROBES = 4）
- **优化建议**: 
  - **简化建议**: 
    - 如果性能是主要关注点，考虑使用更简单的实现（如仅在第一次击中时应用模糊）
    - 减少速度探针数量或使用更智能的探针选择策略
  - **重构建议**: 
    - 提取速度检测逻辑到单独函数
    - 提取光线偏移计算到单独函数
  - **性能优化**: 
    - 如果物体运动模糊很少使用，可以将其设为可选功能
    - 考虑使用时间累积而不是每帧多次追踪

---

## shader.hlsl

**作用**: 主着色器文件，包含所有模块并实现入口点（RayGen、Miss、ClosestHit）。

### 入口点函数

#### `[shader("raygeneration")] void RayGenMain()`
- **功能**: 光线生成着色器入口点
- **用途**: 主渲染循环
- **问题**: 
  - 代码较长（160+ 行），包含大量逻辑
  - MSAA 采样逻辑复杂
  - 包含大量数值保护代码
- **优化建议**: 
  - **重构建议**: 将主循环拆分为多个函数：
    - `ComputeMSAAJitter()`: MSAA 抖动计算
    - `GenerateRayWithEffects()`: 生成带效果的光线（景深、运动模糊）
    - `AccumulateSample()`: 累积采样结果
    - `ApplyToneMapping()`: 色调映射和最终输出
  - **简化建议**: 
    - 如果某些 MSAA 模式很少使用，可以简化相关逻辑
    - 检查数值保护是否真的必要

#### `[shader("miss")] void MissMain(inout RayPayload payload)`
- **功能**: 未击中着色器
- **用途**: 处理未击中光线（返回天空盒）
- **优化建议**: 无

#### `[shader("closesthit")] void ClosestHitMain(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attr)`
- **功能**: 最近击中着色器
- **用途**: 处理光线击中，计算法线和UV
- **优化建议**: 无

---

## disney.glsl

**作用**: Disney BSDF 实现（GLSL版本），可能未在当前HLSL管线中使用。

### 说明

- 此文件使用 GLSL 语法，而项目主要使用 HLSL
- 可能是一个参考实现或遗留代码
- 如果未使用，可以考虑移除或转换为 HLSL

### 优化建议

- **如果未使用**: 移除此文件，减少代码库复杂度
- **如果需要保留**: 添加注释说明这是参考实现，不用于实际渲染

---

## 总结

### 主要问题

1. **硬编码值过多**: 实体ID范围、纹理数量上限、最大弹射次数等
2. **数值保护代码过多**: 大量 MAX/MIN 限制，可能掩盖真正的问题
3. **代码过长**: 某些函数（如 `TracePathWithObjectMotionBlur`）超过200行
4. **功能重复**: 某些功能在多个地方实现
5. **未使用的函数**: 某些函数（如快门形状函数）定义了但未使用

### 优化优先级

1. **高优先级**: 
   - 重构长函数（`TracePathWithObjectMotionBlur`, `RayGenMain`）
   - 移除未使用的函数
   - 将硬编码值改为可配置参数

2. **中优先级**: 
   - 简化数值保护代码（检查是否真的必要）
   - 统一重复的功能实现
   - 优化物体运动模糊实现（性能问题）

3. **低优先级**: 
   - 改进注释和文档
   - 代码风格统一
   - 添加更多错误处理

