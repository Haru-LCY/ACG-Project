# Normal Map 实现文档

## 概述
本文档描述了在光线追踪渲染器中实现的法线贴图（Normal Mapping）功能。法线贴图允许在不增加几何复杂度的情况下，通过纹理存储表面细节法线来显著提升视觉细节。

## 实现的文件

### 1. 新增文件
- **`src/shaders/normal_map.hlsl`**: 法线贴图着色器实现
  - `SampleNormalMap()`: 基础法线贴图采样（需要预先计算的切线基）
  - `SampleNormalMapSimple()`: 简化版本（自动计算切线）
  - `ComputeTangentBasis()`: 从三角形顶点计算切线和副切线
  - `SampleNormalMapFull()`: 完整版本（包含切线计算）

### 2. 修改的文件

#### C++ 代码
- **`src/Material.h`**:
  - 添加了 `normal_map_id` 字段到 Material 结构体
  - 移除了 `padding3` 字段（被 `normal_map_id` 替代）
  - 更新了所有构造函数以初始化 `normal_map_id = -1`

- **`src/Entity.h`**:
  - 构造函数新增 `normal_map_path` 参数
  - 添加 `LoadNormalMap()` 方法
  - 添加 `GetNormalMap()` 和 `HasNormalMap()` getter 方法
  - 添加 `SetNormalMapId()` setter 方法
  - 添加 `normal_map_` 成员变量
  - 添加 `normal_map_path_` 成员变量

- **`src/Entity.cpp`**:
  - 更新构造函数以接收和存储 normal_map_path
  - 实现 `LoadNormalMap()` 方法（与 LoadTexture 类似）
  - 在 `BuildBLAS()` 中添加法线贴图加载逻辑
  - 更新析构函数以清理 normal_map_ 资源

- **`src/Scene.cpp`**:
  - 修改 `CollectTextures()` 方法以同时收集基础纹理和法线贴图
  - 为法线贴图分配纹理数组索引
  - 更新日志信息以区分基础纹理和法线贴图

- **`src/app.cpp`**:
  - 添加了一个使用法线贴图的立方体示例
  - 使用路径 `"textures/normal.png"` 作为法线贴图

#### HLSL 着色器代码
- **`src/shaders/common.hlsl`**:
  - 在 Material 结构体中添加 `normal_map_id` 字段
  - 移除了 `padding3` 字段

- **`src/shaders/shader.hlsl`** (ClosestHitMain 函数):
  - 在计算几何法线后添加了法线贴图应用逻辑
  - 从三角形顶点计算切线和副切线（TBN 基）
  - 从法线贴图采样并转换到世界空间
  - 使用 Gram-Schmidt 正交化过程确保 TBN 基的正交性

## 使用方法

### 在代码中使用法线贴图

```cpp
// 创建带法线贴图的实体
auto entity = std::make_shared<Entity>(
    "meshes/cube.obj",                    // 模型路径
    Material(glm::vec3(0.8f, 0.8f, 0.8f), 0.5f, 0.0f),  // 材质
    glm::mat4(1.0f),                      // 变换矩阵
    "",                                    // 基础纹理路径（可选）
    "textures/normal.png"                 // 法线贴图路径
);
scene->AddEntity(entity);
```

### 法线贴图格式要求
- 格式：RGB 图像（PNG, JPG 等）
- 颜色空间：切线空间法线贴图
- 编码：
  - R: 切线空间 X 分量（红色通道）
  - G: 切线空间 Y 分量（绿色通道）
  - B: 切线空间 Z 分量（蓝色通道）
  - 值域：[0, 1] 映射到 [-1, 1]
- 通常表现为蓝紫色（因为 Z 分量通常为正）

### 示例场景中的法线贴图物体
在 `app.cpp` 的 `OnInit()` 函数中添加了一个演示立方体：
- 位置：(-2.0, 0.5, 3.0)
- 材质：灰色漫反射
- 法线贴图：`C:\Users\lenovo\Desktop\ACG-Project\external\LongMarch\assets\textures\normal.png`

## 技术细节

### 切线空间（Tangent Space）
法线贴图存储在切线空间中，这是一个以三角形表面为基准的局部坐标系：
- **T (Tangent)**: 切线，沿 U 方向
- **B (Bitangent)**: 副切线，沿 V 方向
- **N (Normal)**: 几何法线

### TBN 矩阵计算
从三角形的顶点位置和 UV 坐标计算：

```hlsl
// 边向量
edge1 = p1 - p0
edge2 = p2 - p0

// UV 增量
deltaUV1 = uv1 - uv0
deltaUV2 = uv2 - uv0

// 计算切线和副切线
f = 1.0 / (deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y)
T = f * (deltaUV2.y * edge1 - deltaUV1.y * edge2)
B = f * (-deltaUV2.x * edge1 + deltaUV1.x * edge2)
```

### Gram-Schmidt 正交化
确保 TBN 基是正交的：

```hlsl
T = normalize(T - N * dot(N, T))
B = normalize(B - N * dot(N, B) - T * dot(T, B))
```

### 法线转换
从切线空间转换到世界空间：

```hlsl
float3x3 TBN = float3x3(T, B, N)
worldNormal = normalize(mul(tangentNormal, TBN))
```

## 性能考虑

1. **额外计算开销**：
   - 每个启用法线贴图的物体需要计算 TBN 矩阵
   - 需要额外的纹理采样

2. **内存使用**：
   - 法线贴图被添加到纹理数组中
   - 共享同一个 MAX_TEXTURES (64) 的限制

3. **优化建议**：
   - 仅对需要细节的物体使用法线贴图
   - 考虑使用压缩的法线贴图格式
   - 可以预计算切线并存储在顶点缓冲区中（未实现）

## 限制和未来改进

### 当前限制
1. 切线在运行时计算，没有利用 OBJ 文件中可能存在的切线数据
2. 没有处理镜像 UV 的情况（可能导致切线不连续）
3. 法线贴图和基础纹理共享同一个纹理数组槽位

### 未来改进方向
1. **预计算切线**：在网格加载时计算并存储切线
2. **支持法线贴图压缩**：BC5/BC7 压缩格式
3. **切线空间光照**：在切线空间中进行光照计算（可能更高效）
4. **MikkTSpace**：使用标准的切线计算方法确保一致性
5. **视差贴图**：基于法线贴图的高度信息进行视差映射

## 验证和测试

### 测试场景
- 包含一个使用法线贴图的立方体
- 位于 (-2.0, 0.5, 3.0)
- 使用 `textures/normal.png`

### 验证方法
1. 检查表面是否显示细节（而不是平滑表面）
2. 旋转相机观察法线如何影响光照
3. 与没有法线贴图的物体对比

## 相关资源

- [LearnOpenGL - Normal Mapping](https://learnopengl.com/Advanced-Lighting/Normal-Mapping)
- [Mikkelsen, M. (2008). MikkTSpace](http://www.mikktspace.com/)
- [Blender Normal Map Baking](https://docs.blender.org/manual/en/latest/render/cycles/baking.html)

## 作者和日期
- 实现日期：2025年12月3日
- 功能：Normal Mapping for Ray Tracing
