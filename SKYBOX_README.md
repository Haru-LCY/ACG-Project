# Skybox / HDR Environment Lighting

本项目支持 HDR 环境贴图（Skybox）和程序化天空两种环境光照模式。

## 功能特性

### 1. HDR 环境贴图
- 支持等距柱状投影（Equirectangular）格式的 HDR 图像
- 支持 `.hdr` 和 `.exr` 格式（通过 stb_image 加载）
- 可调节环境光强度
- 可调节环境贴图旋转角度

### 2. 程序化天空
- 自定义天顶、地平线和地面颜色
- 平滑的颜色渐变过渡
- 无需外部资源文件

### 3. 太阳/方向光
- 可配置的太阳方向
- 可调节的太阳强度和颜色

## 使用方法

### 加载 HDR 环境贴图

1. **准备 HDR 图像**：
   - 将 HDR 环境贴图放置在 `textures/` 文件夹中
   - 推荐命名为 `environment.hdr` 或 `skybox.hdr`
   - 支持从 [Poly Haven](https://polyhaven.com/hdris) 等网站下载免费 HDRI

2. **在 UI 中加载**：
   - 在左侧面板找到 "Environment Lighting" 部分
   - 输入 HDR 文件路径（如 `textures/environment.hdr`）
   - 点击 "Load HDR" 按钮

3. **调整参数**：
   - `Env Intensity`：控制环境光整体亮度
   - `Env Rotation`：旋转环境贴图（用于调整光照方向）

### 使用程序化天空

如果没有加载 HDR 环境贴图，系统会使用程序化天空：

1. **调整天空颜色**：
   - `Zenith`：天顶颜色（正上方）
   - `Horizon`：地平线颜色
   - `Ground`：地面颜色（正下方）

2. **切换到程序化天空**：
   - 点击 "Use Procedural Sky" 按钮

### 配置太阳光

1. 调节 `Sun Intensity` 开启太阳光
2. 使用 `Sun Color` 调整颜色
3. 使用 `Sun Direction` 调整方向

## 推荐 HDRI 资源

以下是一些提供免费 HDRI 的网站：

- [Poly Haven](https://polyhaven.com/hdris) - 高质量免费 HDRI
- [HDRI Haven](https://hdrihaven.com/) - 同 Poly Haven
- [sIBL Archive](http://www.hdrlabs.com/sibl/archive.html) - 免费 sIBL 资源

## 技术细节

### 坐标系统
- 使用等距柱状投影（Equirectangular Projection）
- Y 轴向上
- UV 坐标映射：U = 水平角度，V = 垂直角度

### Shader 实现
- `skybox.hlsl`：环境贴图采样和 IBL 计算
- `SampleEnvironmentMap()`：采样环境贴图
- `GetProceduralSky()`：程序化天空颜色
- `ComputeEnvironmentLighting()`：完整的 IBL 光照

### 资源绑定
- `space16`：SkyboxInfo 常量缓冲区
- `space17`：HDR 环境贴图
- `space18`：环境贴图采样器

## 性能考虑

- HDR 环境贴图会增加显存使用
- 使用 LOD 采样可以提高模糊反射的性能
- 程序化天空不需要额外显存

## 已知限制

- 当前不支持立方体贴图格式
- 不支持预计算的辐照度贴图
- 太阳光不会产生阴影（简化实现）
