# Principled BSDF Implementation

## 概述

本项目已成功实现了完整的 **Principled BSDF** (基于 Disney 的 Principled BSDF 模型)，用于物理真实的材质渲染。

## 功能特性

Principled BSDF 包含以下参数，可以创建各种真实材质效果：

### 基础参数
- **base_color** (vec3): 材质的基础颜色
- **roughness** (float, 0-1): 表面粗糙度，0=光滑镜面，1=完全粗糙
- **metallic** (float, 0-1): 金属度，0=电介质，1=金属

### 镜面反射参数
- **specular** (float, 0-1): 镜面反射强度，默认0.5
- **specular_tint** (float, 0-1): 用基础色对镜面反射着色的程度

### 各向异性参数
- **anisotropic** (float, 0-1): 各向异性程度，用于刷过的金属等
- **anisotropic_rotation** (float, 0-1): 各向异性的旋转角度

### 织物参数 (Sheen)
- **sheen** (float, 0-1): 织物光泽强度，用于模拟天鹅绒、缎面等
- **sheen_tint** (float, 0-1): 用基础色对织物光泽着色的程度

### 清漆层参数 (Clearcoat)
- **clearcoat** (float, 0-1): 清漆层强度，用于车漆等
- **clearcoat_roughness** (float, 0-1): 清漆层粗糙度

### 透明参数
- **transmission** (float, 0-1): 透明度，0=不透明，1=完全透明
- **transmission_roughness** (float, 0-1): 透明的粗糙度（毛玻璃效果）
- **ior** (float, 1.0-3.0): 折射率，玻璃约1.45-1.5
- **transmission_color** (vec3): 透射颜色/吸收色

### 次表面散射参数
- **subsurface** (float, 0-1): 次表面散射强度
- **subsurface_color** (vec3): 次表面散射颜色
- **subsurface_radius** (vec3): 次表面散射半径 (RGB通道)

### 自发光参数
- **emission_color** (vec3): 自发光颜色
- **emission_strength** (float): 自发光强度

## 使用示例

### C++ 中创建材质

```cpp
// 创建一个金属材质
Material metal_material;
metal_material.base_color = glm::vec3(0.7f, 0.7f, 0.8f);
metal_material.roughness = 0.2f;
metal_material.metallic = 1.0f;
metal_material.specular = 1.0f;

// 创建一个粗糙塑料材质
Material plastic_material;
plastic_material.base_color = glm::vec3(0.8f, 0.2f, 0.2f);
plastic_material.roughness = 0.5f;
plastic_material.metallic = 0.0f;
plastic_material.specular = 0.5f;

// 创建一个玻璃材质
Material glass_material;
glass_material.base_color = glm::vec3(1.0f, 1.0f, 1.0f);
glass_material.roughness = 0.0f;
glass_material.metallic = 0.0f;
glass_material.transmission = 1.0f;
glass_material.ior = 1.45f;

// 创建一个各向异性金属（刷过的铝）
Material brushed_metal;
brushed_metal.base_color = glm::vec3(0.9f, 0.9f, 0.9f);
brushed_metal.roughness = 0.3f;
brushed_metal.metallic = 1.0f;
brushed_metal.anisotropic = 0.8f;
brushed_metal.anisotropic_rotation = 0.25f; // 90度旋转

// 创建一个带清漆的车漆
Material car_paint;
car_paint.base_color = glm::vec3(0.8f, 0.1f, 0.1f);
car_paint.roughness = 0.3f;
car_paint.metallic = 0.5f;
car_paint.clearcoat = 1.0f;
car_paint.clearcoat_roughness = 0.05f;

// 创建一个天鹅绒织物
Material velvet;
velvet.base_color = glm::vec3(0.3f, 0.1f, 0.5f);
velvet.roughness = 1.0f;
velvet.metallic = 0.0f;
velvet.sheen = 1.0f;
velvet.sheen_tint = 0.5f;

// 创建一个发光材质
Material emissive;
emissive.base_color = glm::vec3(1.0f, 1.0f, 1.0f);
emissive.emission_color = glm::vec3(1.0f, 0.8f, 0.6f);
emissive.emission_strength = 10.0f;
```

## 技术细节

### 实现的功能
1. **各向异性GGX微表面模型**: 支持各向异性的镜面反射
2. **Fresnel项**: 使用Schlick近似实现菲涅尔效应
3. **多重重要性采样 (MIS)**: 在直接光照中使用Balance启发式
4. **分层采样策略**: 根据材质属性智能选择漫反射/镜面/清漆层采样
5. **能量守恒**: 确保BRDF满足物理约束
6. **织物模型**: 基于Estevez & Kulla的织物BRDF
7. **清漆层**: 独立的清漆微表面层，模拟涂层效果

### 性能优化
- 使用重要性采样减少方差
- 智能的lobe选择减少不必要的计算
- 俄罗斯轮盘赌提前终止低贡献路径

## 注意事项

1. **内存对齐**: Material结构体使用16字节对齐，确保GPU和CPU端布局一致
2. **参数范围**: 大部分参数范围为0-1，超出范围可能导致非物理结果
3. **性能影响**: 完整的Principled BSDF比简化模型更耗性能，但提供更真实的效果
4. **次表面散射**: 当前版本的subsurface参数已定义但未完全实现，将在未来版本中完善


