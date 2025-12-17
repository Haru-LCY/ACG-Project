# Shaders 光线追踪代码文档

本文档详细说明 `src/shaders/` 目录下所有文件的功能、函数作用以及优化建议。

---

## 目录

- [common.hlsl](#commonhlsl) - 通用结构体和资源定义
- [rng.hlsl](#rnghlsl) - 随机数生成
- [geometry.hlsl](#geometryhlsl) - 几何计算工具
- [bsdf.hlsl](#bsdfhlsl) - BSDF 材质模型实现
- [lighting.hlsl](#lightinghlsl) - 光源计算和阴影
- [raygen.hlsl](#raygenhlsl) - 相机光线生成
- [raytracing.hlsl](#raytracinghlsl) - 路径追踪核心逻辑
- [skybox.hlsl](#skyboxhlsl) - 天空盒和环境光照
- [normal_map.hlsl](#normal_maphlsl) - 法线贴图和视差贴图
- [motion_blur.hlsl](#motion_blurhlsl) - 运动模糊效果
- [msaa.hlsl](#msaahlsl) - 多重采样抗锯齿
- [shader.hlsl](#shaderhlsl) - 主着色器入口点
- [disney.glsl](#disneyglsl) - Disney BSDF 参考实现

---

## common.hlsl

**作用**: 定义光线追踪系统所需的所有结构体、常量缓冲区和资源绑定。

### 主要结构体

- `CameraInfo`: 相机参数（变换矩阵、景深、曝光、MSAA、运动模糊等）
- `Material`: Principled BSDF 材质参数（颜色、粗糙度、金属度、透射等）
- `PointLight`: 点光源（位置、强度、颜色、半径）
- `AreaLight`: 面光源（位置、尺寸、方向、颜色）
- `RayPayload`: 光线追踪载荷（击中信息、材质索引、法线、UV等）
- `SkyboxInfo`: 天空盒信息（环境贴图、程序化天空、太阳参数）
- `EntityOffset`: 实体在全局缓冲区中的偏移量

### 资源绑定

- `as`: 光线追踪加速结构
- `output`: 输出纹理
- `materials`: 材质数组
- `point_lights`: 点光源数组
- `area_lights`: 面光源数组
- `textures`: 纹理数组
- `global_vertices/normals/texcoords/indices`: 全局几何缓冲区
- `environment_map`: HDR 环境贴图

### 常量定义

- `MAX_TEXTURES = 64`: 最大纹理数量
- `MAX_PATH_BOUNCES = 8`: 路径追踪最大弹射次数
- `MAX_SHADOW_BOUNCES = 6`: 阴影追踪最大弹射次数

### 优化建议

1. **结构体对齐**: 当前 `Material` 结构体有多个 `padding` 字段，可以考虑重新排列字段顺序以减少填充。
2. **常量硬编码**: `MAX_TEXTURES`、`MAX_PATH_BOUNCES` 等可以考虑改为运行时可配置。
3. **资源空间管理**: 当前使用了多个 `space`，可以合并一些不冲突的资源到同一空间。

---

## rng.hlsl

**作用**: 提供随机数生成功能，用于蒙特卡洛采样。

### 函数列表

#### `PCGHash(inout uint state) -> uint`
- **功能**: PCG 哈希函数，生成伪随机数
- **在光线追踪中的作用**: 作为随机数生成器的核心，用于所有需要随机采样的地方（BSDF采样、光源采样、时间采样等）
- **优化建议**: 
  - 当前实现已经比较高效，但可以考虑使用更快的哈希函数（如 xxHash）如果性能是瓶颈
  - 可以考虑预计算一些随机数序列以减少运行时计算

#### `Rand01(inout uint state) -> float`
- **功能**: 生成 [0, 1) 范围的随机浮点数
- **在光线追踪中的作用**: 所有需要均匀随机数的地方都使用此函数
- **优化建议**: 无，实现简洁高效

#### `SampleUnitDisk(inout uint seed) -> float2`
- **功能**: 在单位圆盘内均匀采样一个点
- **在光线追踪中的作用**: 用于景深效果（DOF），在光圈上采样偏移点
- **优化建议**: 
  - 当前使用极坐标采样，可以考虑使用分层采样（Stratified Sampling）提高收敛速度
  - 可以添加重要性采样版本（如高斯分布采样）用于更自然的景深效果

### 优化建议

1. **分层采样**: 可以添加分层采样函数，提高蒙特卡洛采样的效率
2. **低差异序列**: 可以考虑使用 Halton 序列或 Sobol 序列替代纯随机数，提高收敛速度

---

## geometry.hlsl

**作用**: 提供几何计算工具函数，包括法线计算、UV坐标计算等。

### 函数列表

#### `ComputeFaceNormal(float3 v0, v1, v2) -> float3`
- **功能**: 计算三角形的面法线（使用顶点叉积）
- **在光线追踪中的作用**: 当 OBJ 文件中没有顶点法线时，计算面法线作为后备
- **优化建议**: 
  - 当前实现有退化三角形检查，但阈值 `1e-6` 可能需要根据场景调整
  - 可以考虑使用更稳定的叉积计算方法（如 Kahan 求和）

#### `GetVertexNormal(uint entity_id, primitive_id, float2 barycentrics) -> float3`
- **功能**: 从全局缓冲区获取顶点法线，如果都是占位符则计算面法线
- **在光线追踪中的作用**: 在 `ClosestHitMain` 中获取击中点的法线
- **优化建议**: 
  - 占位符检查使用 `length(n) < 0.001`，可以考虑使用更精确的检查（如 `n == float3(0,0,0)`）
  - 重心坐标插值前可以添加归一化检查，避免插值后法线长度异常

#### `ComputeSimpleUV(float3 objectPos, float3 normal) -> float2`
- **功能**: 根据顶点位置和法线计算简单的UV坐标（平面投影）
- **在光线追踪中的作用**: 当 OBJ 文件中没有UV坐标时，计算UV作为后备
- **优化建议**: 
  - 当前实现根据法线的主要方向选择投影面，逻辑较复杂，可以考虑简化
  - UV计算中的 `* 0.5 + 0.5` 可以提取为常量，避免重复计算
  - 可以考虑使用更简单的UV映射（如球面投影）在某些情况下效果更好

#### `GetVertexUV(uint entity_id, primitive_id, float2 barycentrics, float3 objectPos, float3 normal) -> float2`
- **功能**: 从全局缓冲区获取UV坐标，如果都是占位符则计算UV
- **在光线追踪中的作用**: 在 `ClosestHitMain` 中获取击中点的UV坐标
- **优化建议**: 
  - 占位符检查使用 `uv.x < -0.9 && uv.y < -0.9`，可以考虑使用更精确的检查
  - V轴翻转（`1.0 - interpolated_uv.y`）是必要的（OBJ坐标系到DirectX坐标系），但可以添加注释说明

### 优化建议

1. **代码重复**: `GetVertexNormal` 和 `GetVertexUV` 都有获取三角形顶点的逻辑，可以提取为公共函数
2. **边界情况**: 当前对退化三角形和占位符的处理比较完善，但可以添加更多注释说明这些边界情况
3. **性能优化**: 可以考虑缓存一些计算结果（如切空间基向量）如果同一三角形被多次访问

---

## bsdf.hlsl

**作用**: 实现 Principled BSDF 材质模型，包括漫反射、镜面反射、清漆层、各向异性等。

### 函数列表

#### `PowerHeuristic(float pdf_a, pdf_b) -> float`
- **功能**: MIS（多重重要性采样）的 Power heuristic（β=2）
- **在光线追踪中的作用**: 用于光源采样和BSDF采样的权重混合
- **优化建议**: 
  - 当前实现使用 `1e-8` 防止除零，可以考虑使用更小的值或使用 `max(pdf_a + pdf_b, 1e-8)`
  - 可以考虑添加 Balance heuristic 的对比，让用户选择使用哪种

#### `BalanceHeuristic(float pdf_a, pdf_b) -> float`
- **功能**: MIS 的 Balance heuristic
- **在光线追踪中的作用**: 用于光源采样和BSDF采样的权重混合
- **优化建议**: 同 `PowerHeuristic`

#### `SampleCosineHemisphere(float3 n, inout uint seed, out float pdf) -> float3`
- **功能**: 余弦加权的半球采样（Lambertian 漫反射采样）
- **在光线追踪中的作用**: 用于漫反射 lobe 的重要性采样
- **优化建议**: 
  - 当前实现使用极坐标采样，可以考虑使用分层采样提高收敛速度
  - 切空间基构建逻辑（`abs(n.z) < 0.999`）可以提取为独立函数

#### `GetMaterialBaseColor(Material mat, float2 uv) -> float3`
- **功能**: 获取材质的基础颜色（考虑纹理）
- **在光线追踪中的作用**: 在BSDF评估和采样时获取材质颜色
- **优化建议**: 
  - 当前实现有纹理ID边界检查，但 `MAX_TEXTURES` 是编译时常量，可以考虑使用 `[unroll]` 提示编译器优化
  - 可以考虑添加纹理采样缓存（如果同一UV被多次访问）

#### `FresnelSchlick(float cosTheta, float3 F0) -> float3`
- **功能**: Schlick Fresnel 近似
- **在光线追踪中的作用**: 计算菲涅尔反射系数
- **优化建议**: 
  - 当前实现使用 `pow(1.0 - cosTheta, 5.0)`，可以考虑使用更快的近似（如 `(1.0 - cosTheta)^5` 的手动展开）
  - 但通常 `pow` 在GPU上已经优化得很好，这个优化可能不明显

#### `Refract(float3 I, N, float eta, out float3 refracted) -> bool`
- **功能**: Snell's Law 折射计算
- **在光线追踪中的作用**: 用于透明材质的折射
- **优化建议**: 
  - 当前实现检查全反射（`cost2 < 0.0`），逻辑清晰
  - 可以考虑添加更详细的注释说明折射方向的计算公式

#### `FresnelDielectric(float cosThetaI, float etaI, float etaT) -> float`
- **功能**: 介质 Fresnel（用于透明材质）
- **在光线追踪中的作用**: 计算透明材质的菲涅尔反射系数
- **优化建议**: 
  - 当前实现处理了进入/离开介质的情况，逻辑较复杂但必要
  - 可以考虑添加注释说明为什么需要交换 `etaI` 和 `etaT`

#### `BuildOrthonormalBasis(float3 N, out float3 T, out float3 B)`
- **功能**: 从法线构建正交基（切线和副切线）
- **在光线追踪中的作用**: 用于各向异性BSDF和法线贴图
- **优化建议**: 
  - 当前实现使用 `abs(N.z) < 0.999` 选择上向量，逻辑清晰
  - 可以考虑使用更稳定的方法（如 Gram-Schmidt 正交化）

#### `ComputeAnisotropicAlpha(float roughness, float anisotropic, out float alpha_x, out float alpha_y)`
- **功能**: 计算各向异性 alpha 值
- **在光线追踪中的作用**: 用于各向异性GGX分布
- **优化建议**: 
  - 当前实现使用 `sqrt(1.0 - anisotropic * 0.9)`，可以考虑提取 `0.9` 为常量
  - 公式可以添加注释说明来源

#### `ComputeSpecularColor(Material mat, float3 baseColor, out float3 spec_color, out float3 F0)`
- **功能**: 计算镜面反射颜色和 F0
- **在光线追踪中的作用**: 用于镜面反射 lobe 的颜色计算
- **优化建议**: 
  - 亮度计算使用 `dot(baseColor, float3(0.299, 0.587, 0.114))`，这是标准的RGB到亮度转换
  - 可以考虑提取亮度转换矩阵为常量

#### `ComputeLobeWeights(float3 F, kD, float clearcoat, out float diffuse_weight, out float specular_weight, out float clearcoat_weight)`
- **功能**: 计算各 lobe 的权重
- **在光线追踪中的作用**: 用于BSDF采样时的 lobe 选择
- **优化建议**: 
  - 当前实现使用 `max(max(...))` 计算最大分量，可以考虑使用 `max3()` 函数（如果编译器支持）
  - 权重归一化逻辑清晰，但可以添加注释说明为什么需要归一化

#### `GGX_D(float3 H, N, T, B, float roughness, float anisotropic) -> float`
- **功能**: GGX 微表面法线分布函数（支持各向异性）
- **在光线追踪中的作用**: 计算镜面反射的分布项
- **优化建议**: 
  - 当前实现有大量的数值稳定性保护（`MIN_V2`、`MAX_W2`、`MAX_D`），这是必要的，但可以考虑：
    - 将这些常量提取为宏或常量，方便调整
    - 添加注释说明为什么需要这些保护
    - 可以考虑使用更稳定的计算方法（如使用 `log` 空间计算）

#### `GGX_G1(float3 V, N, T, B, float roughness, float anisotropic) -> float`
- **功能**: GGX 几何项（Smith G1），计算自遮挡
- **在光线追踪中的作用**: 计算镜面反射的几何项
- **优化建议**: 
  - 当前实现使用 `abs(dot(N, V))`，这是正确的（考虑双向反射）
  - 可以考虑添加注释说明 Smith 遮挡模型的原理

#### `GGX_G(float3 V, L, N, T, B, float roughness, float anisotropic) -> float`
- **功能**: GGX 几何项（Smith G），计算双向遮挡
- **在光线追踪中的作用**: 计算镜面反射的几何项
- **优化建议**: 无，实现简洁

#### `SampleGGX_Internal(float3 N, V, T, B, float roughness, float anisotropic, float anisotropic_rotation, inout uint seed, out float pdf) -> float3`
- **功能**: GGX 分布采样（各向异性）- 内部版本
- **在光线追踪中的作用**: 用于镜面反射 lobe 的重要性采样
- **优化建议**: 
  - 当前实现处理了各向异性旋转，逻辑较复杂但必要
  - 可以考虑添加注释说明各向异性采样的数学原理
  - PDF 计算中的 `1e-7` 可以提取为常量

#### `SampleGGX(float3 N, V, float roughness, float anisotropic, float anisotropic_rotation, inout uint seed, out float pdf) -> float3`
- **功能**: GGX 分布采样（各向异性）- 外部接口
- **在光线追踪中的作用**: 用于镜面反射 lobe 的重要性采样
- **优化建议**: 
  - 当前实现调用 `BuildOrthonormalBasis` 然后调用内部版本，可以考虑缓存切空间基向量如果被多次调用

#### `EvaluateSheen(float3 V, L, N, float3 base_color, float sheen, float sheen_tint) -> float3`
- **功能**: Sheen BRDF 评估（Estevez & Kulla 模型）
- **在光线追踪中的作用**: 计算织物的绒毛效果
- **优化建议**: 
  - 当前实现使用简化的 Schlick Fresnel，可以考虑使用更精确的模型
  - 但简化版本通常已经足够，性能更好

#### `EvaluateClearcoat(float3 V, L, N, float clearcoat, float clearcoat_roughness, out float pdf) -> float3`
- **功能**: Clearcoat BRDF 评估
- **在光线追踪中的作用**: 计算清漆层（如汽车漆）的反射
- **优化建议**: 
  - 当前实现使用固定的 IOR = 1.5，可以考虑使其可配置
  - Clearcoat 的几何项使用简化版本，可以考虑使用完整的 Smith 模型

#### `SampleClearcoat(float3 N, V, float clearcoat_roughness, inout uint seed, out float pdf) -> float3`
- **功能**: Clearcoat lobe 采样
- **在光线追踪中的作用**: 用于清漆层的重要性采样
- **优化建议**: 
  - 当前实现使用 GGX 采样，逻辑清晰
  - PDF 计算中的 `1e-7` 可以提取为常量

#### `EvaluatePrincipledBSDF(Material mat, float3 V, L, N, float2 uv, out float pdf) -> float3`
- **功能**: Principled BSDF 评估
- **在光线追踪中的作用**: 计算给定入射和出射方向的BRDF值
- **优化建议**: 
  - 当前实现组合了多个 lobe（diffuse、specular、sheen、clearcoat），逻辑清晰但较长
  - 可以考虑：
    - 提取每个 lobe 的评估为独立函数（如果还没有）
    - 添加早期退出（如果某些 lobe 的贡献可忽略）
    - 数值稳定性保护（`MIN_DENOM`、`MAX_SPECULAR`）可以提取为常量

#### `SamplePrincipledBSDF(Material mat, float3 V, N, float2 uv, inout uint seed, out float pdf, out float3 weight) -> float3`
- **功能**: Principled BSDF 采样（重要性采样）
- **在光线追踪中的作用**: 生成新的光线方向用于路径追踪
- **优化建议**: 
  - 当前实现根据权重选择 lobe，然后评估完整BSDF，逻辑清晰
  - 权重限制（`MAX_WEIGHT = 50.0`）可以提取为常量
  - 可以考虑使用分层采样提高收敛速度

### 优化建议

1. **代码组织**: 当前文件较长（456行），可以考虑拆分为多个文件（如 `bsdf_ggx.hlsl`、`bsdf_sheen.hlsl` 等）
2. **常量提取**: 大量的魔法数字（如 `1e-8`、`50.0`、`0.25`）应该提取为命名常量
3. **数值稳定性**: 当前有大量的数值稳定性保护，这是好的，但可以考虑使用更系统的方法（如统一的 epsilon 管理）
4. **性能优化**: 可以考虑使用查找表（LUT）预计算一些复杂函数（如 Fresnel）

---

## lighting.hlsl

**作用**: 实现光源计算和阴影追踪，包括点光源、面光源的直接光照和体积阴影。

### 函数列表

#### `SampleVolumeDensity(float3 pos) -> float`
- **功能**: 简单的体积密度采样（程序化，基于高度）
- **在光线追踪中的作用**: 用于体积渲染和体积阴影
- **优化建议**: 
  - 当前实现硬编码了 `TSINGHUA_BOX_TOP = 1.6`，应该改为可配置参数
  - 密度计算使用线性衰减，可以考虑使用更复杂的噪声函数
  - 返回值 `fogDensity * 1.5` 中的 `1.5` 应该提取为常量

#### `TraceAlphaShadowRGB(float3 rayOrigin, rayDirection, float maxDistance, inout uint seed) -> float3`
- **功能**: Alpha shadow 阴影射线追踪（支持透明材质和体积介质）
- **在光线追踪中的作用**: 计算光源到表面的可见度，支持透明材质的多重弹射和体积阴影
- **优化建议**: 
  - 当前实现非常复杂（152行），包含体积采样、透明材质处理、alpha贴图处理等
  - 可以考虑：
    - 拆分体积采样逻辑为独立函数
    - 拆分透明材质处理为独立函数
    - 提取魔法数字（`VOLUME_STEP_SIZE = 0.05`、`MIN_VISIBILITY = 0.001`）为常量
    - 体积采样使用固定步长，可以考虑自适应步长
    - 提前终止条件可以更智能（如使用重要性采样）

#### `ComputeAreaLightContribution(float3 hitPos, normal, viewDir, Material material, float2 uv, AreaLight light, inout uint seed) -> float3`
- **功能**: 计算面光源的直接光照贡献（使用 Principled BSDF，支持 MIS）
- **在光线追踪中的作用**: 在路径追踪中计算面光源的直接光照
- **优化建议**: 
  - 当前实现使用固定采样数 `NUM_LIGHT_SAMPLES = 1`，可以考虑使其可配置
  - MIS 权重计算使用 `BalanceHeuristic`，可以考虑使用 `PowerHeuristic`
  - PDF 计算中的 `1e-8` 可以提取为常量
  - 可以考虑添加分层采样提高收敛速度

#### `ComputePointLightContribution(float3 hitPos, normal, viewDir, Material material, float2 uv, PointLight light, inout uint seed) -> float3`
- **功能**: 计算点光源的直接光照贡献（使用 Principled BSDF）
- **在光线追踪中的作用**: 在路径追踪中计算点光源的直接光照
- **优化建议**: 
  - 当前实现有大量的数值稳定性保护（`MIN_LIGHT_DISTANCE`、`MIN_RADIUS`、`MAX_ATTENUATION`、`MAX_RADIANCE_PER_LIGHT`），这是必要的
  - 可以考虑：
    - 提取所有常量为命名常量
    - 衰减计算使用平滑曲线，逻辑清晰但可以添加注释说明
    - 可以考虑使用更精确的光源模型（如使用光源半径进行软阴影）

### 优化建议

1. **代码拆分**: `TraceAlphaShadowRGB` 函数过长，应该拆分为多个函数
2. **体积渲染**: 体积采样使用固定步长，性能可能不佳，应该使用自适应步长或重要性采样
3. **常量管理**: 大量的魔法数字应该提取为命名常量
4. **性能优化**: 可以考虑使用光源剔除（如视锥剔除）减少不必要的计算

---

## raygen.hlsl

**作用**: 提供相机光线生成功能，包括基础光线生成和景深效果。

### 函数列表

#### `GenerateCameraRay(uint2 dispatchIndex, float2 jitter, out float3 rayOrigin, out float3 rayDir)`
- **功能**: 生成相机光线（无景深效果）
- **在光线追踪中的作用**: 生成从相机发出的初始光线
- **优化建议**: 
  - 当前实现逻辑清晰，但可以添加注释说明坐标变换的步骤
  - Y轴翻转（`uv.y = 1.0 - uv.y`）可以添加注释说明原因

#### `GenerateCameraRayWithDOF(uint2 dispatchIndex, float2 jitter, inout uint seed, out float3 rayOrigin, out float3 rayDir)`
- **功能**: 生成带景深效果的相机光线
- **在光线追踪中的作用**: 生成带景深模糊的相机光线
- **优化建议**: 
  - 当前实现检查 `aperture <= 0.0001` 来禁用景深，可以考虑提取为常量
  - 焦点计算和光圈采样逻辑清晰，但可以添加注释说明景深原理
  - 可以考虑使用更复杂的光圈形状（如六边形、八边形）而不是圆形

#### `GeneratePickRay(uint2 dispatchIndex, out float3 rayOrigin, out float3 rayDir)`
- **功能**: 生成用于实体选择的光线（无抖动，无景深）
- **在光线追踪中的作用**: 用于鼠标拾取，确保结果稳定
- **优化建议**: 
  - 当前实现与 `GenerateCameraRay` 几乎相同，只是没有抖动，可以考虑提取公共逻辑
  - 可以添加注释说明为什么需要无抖动的光线

### 优化建议

1. **代码重复**: `GenerateCameraRay` 和 `GeneratePickRay` 有重复代码，可以提取公共函数
2. **景深优化**: 可以考虑使用分层采样提高景深效果的收敛速度
3. **注释完善**: 可以添加更多注释说明坐标变换和景深原理

---

## raytracing.hlsl

**作用**: 实现路径追踪的核心逻辑，包括体积渲染、物体运动模糊等高级特性。

### 函数列表

#### `ACESFilm(float3 x) -> float3`
- **功能**: ACES 色调映射（HDR到LDR）
- **在光线追踪中的作用**: 将HDR值映射到LDR范围，解决过曝问题
- **优化建议**: 
  - 当前实现使用标准的ACES曲线，逻辑清晰
  - 可以考虑添加其他色调映射选项（如 Reinhard、Uncharted 2）

#### `Noise3D(float3 p) -> float`
- **功能**: 简单的3D噪声函数
- **在光线追踪中的作用**: 用于体积密度的变化
- **优化建议**: 
  - 当前实现使用简单的哈希噪声，质量较低
  - 可以考虑使用更高质量的噪声（如 Perlin、Simplex、Worley）
  - 但简单噪声性能更好，需要权衡

#### `SampleVolumeProperties(float3 pos) -> float4`
- **功能**: 采样体积密度和发光
- **在光线追踪中的作用**: 用于体积渲染，创建体积光柱效果
- **优化建议**: 
  - 当前实现硬编码了多个常量（`LIGHT_BEAM_RADIUS`、`LIGHT_BEAM_LENGTH` 等），应该提取为常量
  - 遍历所有点光源的性能可能不佳，可以考虑使用空间数据结构（如八叉树）加速
  - 光柱效果的计算逻辑较复杂，可以添加注释说明

#### `PhaseFunctionHG(float cosTheta, float g) -> float`
- **功能**: Henyey-Greenstein 相位函数
- **在光线追踪中的作用**: 用于体积散射，计算前向/后向散射
- **优化建议**: 
  - 当前实现使用 `pow(max(denom, 0.0001), 1.5)`，可以考虑提取 `1e-4` 为常量
  - 可以添加注释说明相位函数的物理意义

#### `ComputeSingleScattering(float3 pos, viewDir, float density, inout uint seed) -> float3`
- **功能**: 计算单次散射贡献
- **在光线追踪中的作用**: 用于体积渲染，计算从光源到采样点的散射
- **优化建议**: 
  - 当前实现遍历所有点光源和面光源，性能可能不佳
  - 可以考虑使用重要性采样选择光源
  - 散射系数 `SCATTERING_COEFF` 和相位参数 `G_PHASE` 应该提取为常量

#### `IntegrateVolumeAlongRay(float3 rayOrigin, rayDir, float maxDist, float3 throughput, inout uint seed) -> VolumeIntegrationResult`
- **功能**: 沿光线积分体积贡献（体积发光 + 单次散射）
- **在光线追踪中的作用**: 在路径追踪中计算体积介质的贡献
- **优化建议**: 
  - 当前实现使用自适应步长，这是好的
  - 但步长计算逻辑较复杂，可以提取为独立函数
  - 常量（`MIN_STEP_SIZE`、`MAX_STEP_SIZE`、`DENSITY_THRESHOLD_LOW` 等）应该提取为命名常量
  - 最大步数 `MAX_STEPS = 150` 可能过大，可以考虑根据距离动态调整

#### `TraceRaySimple(float3 rayOrigin, rayDir, float tMin, float tMax, inout RayPayload payload) -> bool`
- **功能**: 简单的光线追踪函数
- **在光线追踪中的作用**: 封装硬件加速的 TraceRay API
- **优化建议**: 无，实现简洁

#### `TracePathWithObjectMotionBlur(float3 rayOrigin, rayDir, float motion_time, inout uint seed) -> float3`
- **功能**: 执行路径追踪（支持物体运动模糊）
- **在光线追踪中的作用**: 路径追踪的主函数，包含直接光照、间接光照、体积渲染等
- **优化建议**: 
  - 当前实现非常复杂（203行），包含大量逻辑
  - 可以考虑：
    - 拆分直接光照计算为独立函数
    - 拆分间接光照计算为独立函数
    - 拆分透明材质处理为独立函数
    - 提取所有常量（`MAX_THROUGHPUT`、`MAX_THROUGHPUT_FOR_LIGHT`、`MAX_RADIANCE_PER_LIGHT` 等）为命名常量
    - 俄罗斯轮盘赌的逻辑可以提取为独立函数
    - 物体运动模糊的逻辑可以提取为独立函数

#### `TracePath(float3 rayOrigin, rayDir, inout uint seed) -> float3`
- **功能**: 标准路径追踪入口函数（不启用物体运动模糊）
- **在光线追踪中的作用**: 路径追踪的简化入口
- **优化建议**: 无，实现简洁

#### `TracePathObjectMotionBlur(float3 rayOrigin, rayDir, inout uint seed) -> float3`
- **功能**: 物体运动模糊的屏幕空间实现
- **在光线追踪中的作用**: 通过反向偏移光线起点模拟物体运动模糊
- **优化建议**: 
  - 当前实现非常复杂（128行），包含大量逻辑
  - 可以考虑：
    - 拆分原始光线追踪为独立函数
    - 拆分偏移光线追踪为独立函数
    - 速度探测逻辑可以优化（当前使用固定数量的探测）
    - 可以添加注释说明反向偏移的原理

### 优化建议

1. **代码拆分**: `TracePathWithObjectMotionBlur` 和 `TracePathObjectMotionBlur` 函数过长，应该拆分为多个函数
2. **常量管理**: 大量的魔法数字应该提取为命名常量
3. **性能优化**: 体积渲染的性能可能不佳，可以考虑使用更高效的算法（如 delta tracking、ratio tracking）
4. **代码组织**: 当前文件包含体积渲染、路径追踪、运动模糊等多个功能，可以考虑拆分为多个文件

---

## skybox.hlsl

**作用**: 实现天空盒和环境光照，包括HDR环境贴图采样和程序化天空。

### 函数列表

#### `DirectionToEquirectangularUV(float3 direction) -> float2`
- **功能**: 将方向向量转换为等距柱状投影 UV 坐标
- **在光线追踪中的作用**: 用于采样HDR环境贴图
- **优化建议**: 
  - 当前实现使用标准的等距柱状投影，逻辑清晰
  - 可以考虑添加其他投影格式的支持（如立方体贴图）

#### `EquirectangularUVToDirection(float2 uv) -> float3`
- **功能**: 从等距柱状投影 UV 坐标转换回方向向量
- **在光线追踪中的作用**: 用于环境光照的重要性采样（当前未使用）
- **优化建议**: 无，实现简洁

#### `SampleEnvironmentMap(float3 direction) -> float3`
- **功能**: 采样 HDR 环境贴图
- **在光线追踪中的作用**: 在 `MissMain` 中采样环境贴图作为背景
- **优化建议**: 
  - 当前实现应用旋转，逻辑清晰
  - 可以考虑添加LOD选择逻辑（根据粗糙度）

#### `SampleEnvironmentMapLOD(float3 direction, float lod) -> float3`
- **功能**: 带 LOD 的环境贴图采样
- **在光线追踪中的作用**: 用于模糊反射（根据粗糙度选择LOD）
- **优化建议**: 
  - 当前实现逻辑清晰
  - 可以考虑添加LOD偏移参数

#### `GetProceduralSky(float3 direction) -> float3`
- **功能**: 程序化天空（作为后备或调试）
- **在光线追踪中的作用**: 当没有环境贴图时使用程序化天空
- **优化建议**: 
  - 当前实现使用简单的线性插值，可以考虑使用更复杂的模型（如 Preetham 天空模型）
  - 但简单模型性能更好，需要权衡

#### `GetEnvironmentIrradiance(float3 normal) -> float3`
- **功能**: 计算漫反射环境光照
- **在光线追踪中的作用**: 用于IBL（当前未在主路径追踪中使用）
- **优化建议**: 
  - 当前实现使用简化的LOD采样，可以考虑使用预计算的辐照度贴图
  - 但简化版本性能更好，需要权衡

#### `GetEnvironmentReflection(float3 reflectionDir, float roughness) -> float3`
- **功能**: 计算镜面反射环境光照
- **在光线追踪中的作用**: 用于IBL（当前未在主路径追踪中使用）
- **优化建议**: 
  - 当前实现根据粗糙度选择LOD，逻辑清晰
  - 可以考虑使用预计算的预过滤环境贴图

#### `CosineSampleHemisphere(float u1, u2, float3 normal) -> float3`
- **功能**: 生成余弦加权半球采样方向
- **在光线追踪中的作用**: 用于漫反射IBL的重要性采样（当前未使用）
- **优化建议**: 无，实现简洁

#### `ImportanceSampleGGX(float u1, u2, float3 normal, float roughness) -> float3`
- **功能**: GGX 重要性采样
- **在光线追踪中的作用**: 用于镜面IBL的重要性采样（当前未使用）
- **优化建议**: 无，实现简洁

#### `ComputeEnvironmentLighting(float3 hitPos, normal, viewDir, Material material, inout uint seed) -> float3`
- **功能**: 计算完整的环境光照贡献（IBL）
- **在光线追踪中的作用**: 用于IBL（当前未在主路径追踪中使用）
- **优化建议**: 
  - 当前实现组合了漫反射和镜面反射，逻辑清晰
  - 可以考虑使用更精确的环境BRDF（如使用查找表）

#### `GetSunDirection() -> float3`
- **功能**: 获取太阳方向
- **在光线追踪中的作用**: 用于太阳光照计算（当前未在主路径追踪中使用）
- **优化建议**: 无，实现简洁

#### `GetSunColor() -> float3`
- **功能**: 获取太阳颜色
- **在光线追踪中的作用**: 用于太阳光照计算（当前未在主路径追踪中使用）
- **优化建议**: 无，实现简洁

#### `ComputeSunLighting(float3 hitPos, normal, viewDir, Material material, inout uint seed) -> float3`
- **功能**: 计算太阳直接光照贡献
- **在光线追踪中的作用**: 用于太阳光照计算（当前未在主路径追踪中使用）
- **优化建议**: 
  - 当前实现使用简化的Blinn-Phong模型，可以考虑使用Principled BSDF
  - 阴影检测被注释掉，应该实现完整的阴影追踪

### 优化建议

1. **功能使用**: 很多函数（如 `ComputeEnvironmentLighting`、`ComputeSunLighting`）在主路径追踪中未使用，可以考虑移除或添加使用
2. **IBL优化**: 当前IBL实现使用简化的方法，可以考虑使用预计算的辐照度贴图和预过滤环境贴图
3. **代码组织**: 当前文件包含环境贴图采样、程序化天空、IBL等多个功能，可以考虑拆分为多个文件

---

## normal_map.hlsl

**作用**: 实现法线贴图和视差贴图（高度贴图），用于增加表面细节。

### 函数列表

#### `ParallaxMapping(Texture2D normalMap, float2 uv, float3 viewDir, T, B, N, float heightScale) -> float2`
- **功能**: 基础视差映射（根据高度值偏移 UV 坐标）
- **在光线追踪中的作用**: 在法线贴图采样前偏移UV坐标，产生视差效果
- **优化建议**: 
  - 当前实现尝试从alpha通道或R通道读取高度，逻辑较复杂
  - 可以考虑：
    - 使用单独的高度贴图纹理（如果可用）
    - 添加注释说明为什么需要从alpha或R通道读取
    - 除零保护（`max(viewDirTS.z, 0.001)`）可以提取为常量

#### `SampleNormalMap(Texture2D normalMap, float2 uv, float3 N, T, B) -> float3`
- **功能**: 从法线贴图采样并转换到世界空间
- **在光线追踪中的作用**: 在 `ClosestHitMain` 中应用法线贴图
- **优化建议**: 
  - 当前实现逻辑清晰，但可以添加注释说明TBN矩阵的构建
  - 可以考虑添加法线贴图强度参数（用于控制扰动强度）

#### `SampleNormalMapSimple(Texture2D normalMap, float2 uv, float3 worldPos, float3 N) -> float3`
- **功能**: 从法线贴图采样（简化版本 - 使用自动计算的切线）
- **在光线追踪中的作用**: 当没有顶点切线数据时使用
- **优化建议**: 
  - 当前实现使用简化的切线计算（`cross(N, float3(0, 1, 0))`），可能不准确
  - 可以考虑使用更稳定的方法（如使用UV梯度）

#### `ComputeTangentBasis(float3 p0, p1, p2, float2 uv0, uv1, uv2, float3 N, out float3 outT, out float3 outB)`
- **功能**: 从顶点数据计算切线和副切线
- **在光线追踪中的作用**: 用于法线贴图的TBN矩阵构建
- **优化建议**: 
  - 当前实现使用标准的Mikkelsen方法，逻辑清晰
  - 正交化使用Gram-Schmidt过程，这是正确的
  - 可以考虑添加退化情况的处理（如UV退化）

#### `SampleNormalMapFull(Texture2D normalMap, float2 uv, float3 p0, p1, p2, float2 uv0, uv1, uv2, float3 N) -> float3`
- **功能**: 从法线贴图采样（完整版本 - 使用三角形顶点数据）
- **在光线追踪中的作用**: 在 `ClosestHitMain` 中使用（当前未使用，使用的是内联实现）
- **优化建议**: 
  - 当前实现逻辑清晰，但未被使用
  - 可以考虑在 `ClosestHitMain` 中使用此函数而不是内联实现

### 优化建议

1. **代码重复**: `ClosestHitMain` 中的法线贴图逻辑与 `SampleNormalMapFull` 重复，应该使用函数而不是内联实现
2. **高度贴图**: 当前高度贴图实现较简单，可以考虑使用更高级的方法（如视差遮蔽映射、陡峭视差映射）
3. **性能优化**: 法线贴图采样在每次击中时都会执行，可以考虑添加缓存（如果同一UV被多次访问）

---

## motion_blur.hlsl

**作用**: 实现运动模糊效果，包括相机运动模糊、物体运动模糊、径向模糊、方向性模糊等。

### 函数列表

#### `SampleTime(inout uint seed) -> float`
- **功能**: 生成随机时间采样点
- **在光线追踪中的作用**: 用于时间域抗锯齿/运动模糊
- **优化建议**: 无，实现简洁

#### `SampleTimeStratified(int sample_index, total_samples, inout uint seed) -> float`
- **功能**: 生成分层时间采样点
- **在光线追踪中的作用**: 用于更均匀的时间分布
- **优化建议**: 无，实现简洁

#### `InterpolateCameraTransform(float4x4 prev_camera_to_world, curr_camera_to_world, float t) -> float4x4`
- **功能**: 计算相机运动模糊偏移（通过插值相机变换矩阵）
- **在光线追踪中的作用**: 用于相机运动模糊（当前未使用）
- **优化建议**: 
  - 当前实现使用简单的线性插值，对于大幅度旋转可能不准确
  - 可以考虑使用四元数插值或SLERP

#### `ComputeRadialBlurOffset(float2 uv, center, float intensity, float t) -> float2`
- **功能**: 计算径向模糊的光线方向偏移
- **在光线追踪中的作用**: 用于径向运动模糊
- **优化建议**: 
  - 当前实现逻辑清晰，但可以添加注释说明径向模糊的原理
  - 除零保护（`dist < 0.001`）可以提取为常量

#### `ComputeDirectionalBlurOffset(float2 direction, float intensity, float t) -> float2`
- **功能**: 计算方向性模糊的UV偏移
- **在光线追踪中的作用**: 用于方向性运动模糊
- **优化建议**: 无，实现简洁

#### `GetEntityVelocity(uint entity_id) -> float3`
- **功能**: 获取实体的速度向量
- **在光线追踪中的作用**: 用于物体运动模糊
- **优化建议**: 
  - 当前实现有边界检查（`entity_id >= MAX_ENTITIES`），这是好的
  - 可以考虑添加注释说明速度的单位（米/秒？）

#### `ComputeObjectMotionBlurPosition(float3 hit_pos, uint entity_id, float t) -> float3`
- **功能**: 计算物体运动模糊的击中点偏移
- **在光线追踪中的作用**: 用于物体运动模糊（当前未在主路径追踪中使用）
- **优化建议**: 
  - 当前实现逻辑清晰，但可以添加注释说明时间偏移的映射

#### `ComputeMotionVector(float3 prev_world_pos, curr_world_pos, float4x4 view_proj, prev_view_proj) -> float2`
- **功能**: 计算运动向量（用于后处理运动模糊）
- **在光线追踪中的作用**: 用于后处理运动模糊（当前未使用）
- **优化建议**: 无，实现简洁

#### `ApplyMotionBlur(inout float3 ray_origin, ray_dir, float2 uv, float shutter_time, float intensity, int mode, inout uint seed)`
- **功能**: 应用运动模糊到光线生成
- **在光线追踪中的作用**: 在 `RayGenMain` 中应用运动模糊
- **优化建议**: 
  - 当前实现支持多种模式，逻辑清晰
  - 但相机运动模糊使用简单的随机抖动，可能不够准确
  - 可以考虑使用更复杂的方法（如使用前一帧的相机变换）

#### `GetRayTime(int sample_index, total_samples, inout uint seed) -> float`
- **功能**: 为光线添加时间信息
- **在光线追踪中的作用**: 用于运动物体的模糊（当前未使用）
- **优化建议**: 无，实现简洁

#### `BoxShutter(float t) -> float`
- **功能**: 盒形快门（均匀分布）
- **在光线追踪中的作用**: 用于快门形状函数（当前未使用）
- **优化建议**: 无，实现简洁

#### `TriangleShutter(float t) -> float`
- **功能**: 三角形快门（中间权重最大）
- **在光线追踪中的作用**: 用于快门形状函数（当前未使用）
- **优化建议**: 无，实现简洁

#### `GaussianShutter(float t) -> float`
- **功能**: 高斯快门（更平滑的过渡）
- **在光线追踪中的作用**: 用于快门形状函数（当前未使用）
- **优化建议**: 无，实现简洁

#### `GenerateCameraRayWithMotionBlur(uint2 dispatch_index, float2 jitter, float motion_blur_intensity, float2 motion_blur_direction, inout uint seed, out float3 ray_origin, out float3 ray_dir)`
- **功能**: 生成带运动模糊的相机光线
- **在光线追踪中的作用**: 用于运动模糊（当前未使用，使用的是 `ApplyMotionBlur`）
- **优化建议**: 
  - 当前实现逻辑清晰，但未被使用
  - 可以考虑统一运动模糊的实现方式

#### `ComputeRotationalBlurOffset(float2 uv, center, float angular_velocity, float t) -> float2`
- **功能**: 计算旋转模糊的偏移
- **在光线追踪中的作用**: 用于旋转运动模糊（当前未使用）
- **优化建议**: 无，实现简洁

#### `ComputeZoomBlurOffset(float2 uv, center, float scale_factor, float t) -> float2`
- **功能**: 计算缩放模糊的偏移（dolly zoom效果）
- **在光线追踪中的作用**: 用于缩放运动模糊（当前未使用）
- **优化建议**: 无，实现简洁

### 优化建议

1. **功能使用**: 很多函数（如 `GenerateCameraRayWithMotionBlur`、`ComputeRotationalBlurOffset`）未被使用，可以考虑移除或添加使用
2. **代码组织**: 当前文件包含多种运动模糊模式，逻辑清晰但可以添加更多注释
3. **性能优化**: 物体运动模糊的性能可能不佳（需要多次光线追踪），可以考虑使用更高效的方法

---

## msaa.hlsl

**作用**: 实现多重采样抗锯齿（MSAA），提供标准MSAA采样模式和子像素抖动生成函数。

### 函数列表

#### `GetMSAASampleCount(int msaa_mode) -> int`
- **功能**: 获取指定 MSAA 模式的采样数量
- **在光线追踪中的作用**: 在 `RayGenMain` 中确定采样数
- **优化建议**: 无，实现简洁

#### `GetMSAASampleOffset(int msaa_mode, int sample_idx, inout uint seed) -> float2`
- **功能**: 获取 MSAA 采样位置
- **在光线追踪中的作用**: 在 `RayGenMain` 中获取子像素偏移
- **优化建议**: 
  - 当前实现支持多种模式，逻辑清晰
  - 随机模式需要包含 `rng.hlsl`，但当前文件未包含，应该添加 `#include "rng.hlsl"`

#### `GetStratifiedSampleOffset(int sample_idx, int total_samples, inout uint seed) -> float2`
- **功能**: 获取分层采样偏移
- **在光线追踪中的作用**: 用于更均匀的随机采样分布（当前未使用）
- **优化建议**: 无，实现简洁

#### `GetR2SampleOffset(int sample_idx) -> float2`
- **功能**: 获取 R2 序列采样偏移
- **在光线追踪中的作用**: 用于低差异序列采样（当前用于时间累积MSAA）
- **优化建议**: 无，实现简洁

#### `HaltonSequence(int index, int base) -> float`
- **功能**: Halton 序列生成
- **在光线追踪中的作用**: 用于低差异序列采样（当前未使用）
- **优化建议**: 无，实现简洁

#### `GetHaltonSampleOffset(int sample_idx) -> float2`
- **功能**: 获取 Halton 序列采样偏移
- **在光线追踪中的作用**: 用于低差异序列采样（当前未使用）
- **优化建议**: 无，实现简洁

#### `GetTemporalMSAASampleOffset(int msaa_mode, int sample_idx, int frame_idx, inout uint seed) -> float2`
- **功能**: 组合模式：标准 MSAA + 时间累积
- **在光线追踪中的作用**: 在 `RayGenMain` 中使用，结合固定模式和帧间偏移
- **优化建议**: 
  - 当前实现逻辑清晰，但可以添加注释说明时间累积的原理
  - `clamp` 操作可以提取为常量

#### `GetMSAASampleWeight(int msaa_mode, int sample_idx) -> float`
- **功能**: 计算采样权重（用于加权平均）
- **在光线追踪中的作用**: 用于非均匀权重（当前未使用）
- **优化建议**: 无，实现简洁

#### `IsMSAAEnabled(int msaa_mode) -> bool`
- **功能**: 检查是否应该使用 MSAA
- **在光线追踪中的作用**: 用于条件判断（当前未使用）
- **优化建议**: 无，实现简洁

### 优化建议

1. **依赖管理**: `GetMSAASampleOffset` 中的随机模式需要 `rng.hlsl`，但文件未包含，应该添加
2. **功能使用**: 很多函数（如 `GetStratifiedSampleOffset`、`GetHaltonSampleOffset`）未被使用，可以考虑移除或添加使用
3. **代码组织**: 当前文件包含多种采样方法，逻辑清晰但可以添加更多注释

---

## shader.hlsl

**作用**: 主着色器文件，包含所有模块并实现入口点（RayGenMain、MissMain、ClosestHitMain）。

### 入口点函数

#### `[shader("raygeneration")] void RayGenMain()`
- **功能**: 光线生成着色器入口点
- **在光线追踪中的作用**: 主入口点，生成相机光线并执行路径追踪
- **优化建议**: 
  - 当前实现非常复杂（162行），包含MSAA、运动模糊、路径追踪、色调映射等
  - 可以考虑：
    - 拆分MSAA逻辑为独立函数
    - 拆分运动模糊逻辑为独立函数
    - 拆分路径追踪逻辑为独立函数
    - 拆分色调映射逻辑为独立函数
    - 提取所有常量（`MAX_SAMPLE_RADIANCE = 1000.0` 等）为命名常量
    - 采样循环可以添加早期退出（如果某些采样贡献可忽略）

#### `[shader("miss")] void MissMain(inout RayPayload payload)`
- **功能**: 光线未击中任何物体时的处理
- **在光线追踪中的作用**: 采样环境贴图或程序化天空
- **优化建议**: 
  - 当前实现逻辑清晰，但可以添加注释说明为什么设置 `material_idx = 0xFFFFFFFF`

#### `[shader("closesthit")] void ClosestHitMain(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attr)`
- **功能**: 光线击中物体时的处理
- **在光线追踪中的作用**: 计算击中点的法线、UV、应用法线贴图等
- **优化建议**: 
  - 当前实现非常复杂（112行），包含法线计算、UV计算、法线贴图等
  - 可以考虑：
    - 拆分法线计算为独立函数
    - 拆分UV计算为独立函数
    - 拆分法线贴图逻辑为独立函数
    - 法线贴图的TBN计算逻辑较复杂，可以提取为独立函数
    - 退化情况的处理（UV退化、切线无效）可以提取为独立函数

### 优化建议

1. **代码拆分**: `RayGenMain` 和 `ClosestHitMain` 函数过长，应该拆分为多个函数
2. **常量管理**: 大量的魔法数字应该提取为命名常量
3. **性能优化**: 可以考虑使用更高效的采样策略（如重要性采样、分层采样）
4. **代码组织**: 当前文件包含所有入口点，逻辑清晰但可以添加更多注释

---

## disney.glsl

**作用**: Disney BSDF 的参考实现（GLSL格式），当前项目未使用，仅作为参考。

### 说明

- 这是一个完整的 Disney BSDF 实现，包含漫反射、镜面反射、清漆层、透射等
- 当前项目的 `bsdf.hlsl` 实现了类似的功能，但实现方式不同
- 此文件可以作为参考，了解 Disney BSDF 的完整实现

### 优化建议

- 如果不需要此文件，可以考虑移除
- 如果需要，可以考虑将其转换为 HLSL 格式并集成到项目中

---

## 总结

### 主要问题

1. **代码组织**: 多个文件过长（如 `bsdf.hlsl`、`raytracing.hlsl`、`shader.hlsl`），应该拆分为多个文件
2. **常量管理**: 大量的魔法数字应该提取为命名常量
3. **代码重复**: 多个函数有重复逻辑，应该提取为公共函数
4. **功能使用**: 很多函数未被使用，可以考虑移除或添加使用
5. **注释完善**: 可以添加更多注释说明复杂逻辑的原理

### 优化优先级

1. **高优先级**: 
   - 提取魔法数字为命名常量
   - 拆分过长的函数
   - 添加关键函数的注释

2. **中优先级**: 
   - 提取重复代码为公共函数
   - 移除未使用的函数
   - 优化性能瓶颈（如体积渲染）

3. **低优先级**: 
   - 代码重组（拆分为更多文件）
   - 添加更多高级功能（如预计算的IBL）

### 清理建议

1. **简化边界情况处理**: 很多函数有大量的边界情况处理，可以考虑：
   - 统一边界情况的处理方式
   - 使用更系统的方法（如统一的 epsilon 管理）
   - 添加注释说明为什么需要这些边界情况处理

2. **减少复杂度**: 很多函数逻辑较复杂，可以考虑：
   - 拆分复杂逻辑为多个简单函数
   - 使用查找表（LUT）预计算复杂函数
   - 简化数学模型（如果精度损失可接受）

3. **性能优化**: 可以考虑：
   - 使用更高效的算法（如重要性采样、分层采样）
   - 减少不必要的计算（如早期退出、光源剔除）
   - 使用空间数据结构加速查询（如八叉树、BVH）

