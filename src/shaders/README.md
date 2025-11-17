# Shader 模块化说明

本目录包含模块化的 HLSL 光线追踪着色器，参考了 sparkium 渲染器的结构设计。

## 文件结构

### 基础数据结构
- **camera_info.hlsl** - 相机和悬停信息结构
- **material.hlsl** - 材质数据结构
- **ray_payload.hlsl** - 光线载荷数据结构
- **constants.hlsl** - 常量定义（PI、EPSILON、MAX_BOUNCES 等）

### 工具函数
- **random.hlsl** - PCG 随机数生成器
- **fresnel.hlsl** - Fresnel 效果计算（Schlick 近似）
- **sampling.hlsl** - 重要性采样函数（余弦加权半球采样）
- **envmap.hlsl** - 环境光/天空盒采样
- **normal_utils.hlsl** - 法线估算工具函数

### 着色函数
- **pbr_shading.hlsl** - PBR 着色和路径追踪逻辑

### 主着色器
- **raytracing.rgen** - 光线生成着色器（主入口点）
- **raytracing.rmiss** - 未击中着色器
- **raytracing.rchit** - 最近击中着色器

## 模块依赖关系

```
raytracing.rgen
├── constants.hlsl
├── camera_info.hlsl
├── material.hlsl
├── ray_payload.hlsl
├── random.hlsl
├── envmap.hlsl
└── pbr_shading.hlsl
    ├── material.hlsl
    ├── fresnel.hlsl
    ├── sampling.hlsl
    │   ├── random.hlsl
    │   └── constants.hlsl
    └── constants.hlsl

raytracing.rchit
├── ray_payload.hlsl
└── normal_utils.hlsl

raytracing.rmiss
└── ray_payload.hlsl
```

## 使用方法

### 编译
确保编译器能找到所有包含文件。主入口点是 `raytracing.rgen`。

### 调试
- 修改采样函数：编辑 `sampling.hlsl`
- 调整材质响应：编辑 `pbr_shading.hlsl` 或 `fresnel.hlsl`
- 修改天空/环境光：编辑 `envmap.hlsl`
- 调整常量（最大反弹次数等）：编辑 `constants.hlsl`
- 修改法线计算：编辑 `normal_utils.hlsl`

### 扩展
添加新功能时，建议创建新的模块文件并在主着色器中引用：
- 新的材质模型 → 创建新的 `.hlsl` 文件
- 新的采样策略 → 扩展 `sampling.hlsl`
- 新的光源类型 → 创建 `lights.hlsl`

## 注意事项

1. **头文件保护**：所有模块都使用 `#ifndef/#define/#endif` 防止重复包含
2. **依赖顺序**：包含文件时注意依赖顺序，被依赖的文件要先包含
3. **常量使用**：使用 `constants.hlsl` 中定义的常量而不是硬编码
4. **随机数**：所有需要随机数的地方使用统一的 PCG 生成器

## 原始文件

原始的单文件版本保存在 `shader.hlsl`（如果需要参考）。
