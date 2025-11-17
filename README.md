# ShortMarch

## Description

This is the official repository for the Advanced Computer Graphics instructed by *Li Yi* at IIIS, Tsinghua University. 

This project contains a simple framework for GPU rendering downgraded from [LongMarch](https://github.com/LazyJazzDev/LongMarch/tree/main) by *Zijian Lyu*.

The demo code is written by *He Li* (TA for 2025 Fall Semester), feel free to contact him if you have any questions.

## Honor Code

You are expected to uphold the principles of academic integrity and honesty in all your work related to this repository. Any form of academic dishonesty, including but not limited to plagiarism, cheating, or unauthorized collaboration, is strictly prohibited and may result in severe consequences. **Any direct copy and paste of code (even from the `external/` code this repository referred) or using AI tools to generate code with knowledge of the subject matter will be considered as cheating**. You are free to read any reference materials, including books, articles, and online resources, to enhance your understanding of the subject matter.

By accessing and using this repository, you acknowledge that you have read, understood, and agreed to abide by this Honor Code. If you do not agree to these terms, you must refrain from using this repository.

## How to build

We recommend using [Visual Studio](https://visualstudio.microsoft.com/) as the IDE for building this project.

### Step 0: Prerequisites

- [vcpkg](https://github.com/microsoft/vcpkg): The C++ package manager. Clone the vcpkg repo to anywhere you like, we will refer tha vcpkg path as
  `<VCPKG_ROOT>` in the following instructions (the path ends in `vcpkg`, not its parent directory).
- [MSVC with Windows SDK (version 10+)](https://visualstudio.microsoft.com/downloads/): We usually install this via Visual Studio installer. You should select the following workloads during installation:
  - Desktop development with C++

  Then everything should be installed automatically.
- [[optional] Python3](https://python.org): We provide python package with pybind11. Such functionality requires Python3 installation. You may install anywhere you like (System-wide, User-only, Conda, Homebrew, etc.). We will refer the python executable path as `<PYTHON_EXECUTABLE_PATH>` in the following instructions.
- [[optional] Vulkan SDK](https://vulkan.lunarg.com/sdk/home): Vulkan is the latest cross-platform graphics API. Since D3D12 is available on Windows, this is optional. Install the SDK [Caution: not the Runtime (RT)] via the official **SDK installer**. You should be able to run `vulkaninfo` command in a new terminal after installation. **No optional components are needed for this project**.
- [[optional] CUDA Toolkit](https://developer.nvidia.com/cuda-downloads): CUDA is optional, however, some functions such as most of the GPU-accelerated physics simulation features will require CUDA. Install the toolkit with the official **exe (local)** installer. You should be able to run `nvcc --version` command in a new terminal after installation.

- ### Step 1: Clone the repo

- Clone this repo with submodules:
  ```bash
  git clone --recurse-submodules
  ```
  or
- Clone without submodules:
  ```bash
  git clone <this-repo-url>
  ```
  Then initialize and update the submodules (in the root directory of this repo):
  ```bash
  git submodule update --init --recursive
  ```

### Step 2: CMake Configuration

In Visual Studio, open the `Project` -> `CMake Settings for Project` menu, and modify the `CMake toolchain file` to: `<VCPKG_ROOT>/scripts/buildsystems/vcpkg.cmake`.

In this process, the CMake script will check whether you have installed Vulkan SDK and CUDA Toolkit, and configure the build options accordingly.

### Step 3: Build and Run

Now you can build and run the project in Visual Studio as usual, selecting the desired target (`ShortMarchDemo.exe` for the demo we provided).

## Bug Shooting

### CMake Configuration Issues

Make sure that you have set the `CMake toolchain file` correctly to `<VCPKG_ROOT>/scripts/buildsystems/vcpkg.cmake`. After any change to the configuration, remember to clean the CMake cache (via `Project` -> `CMake Cache` -> `Delete Cache and Reconfigure` menu in Visual Studio) and reconfigure the project.

### Vulkan Validation Layer Error

If you encounter the following error when running the application:
```
validation layer (ERROR): loader_get_json: Failed to open JSON file </path/to/a/json>
```
where `/path/to/a/json` is a non-existent file, it indicates that the Vulkan validation layers are trying to load a configuration file that does not exist on your system. Hopefully, the </path/to/a/json> is related to your Steam or Epic Games installation. To resolve this issue, you can try the following steps:
1. Press `Win + R` and type `regedit` to open the Registry Editor.
2. Try to find the `</path/to/a/json>` under:
	- `HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\Vulkan\ImplicitLayers`
	- `HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\Vulkan\ExplicitLayers`
	- `HKEY_CURRENT_USER\SOFTWARE\Khronos\Vulkan\ImplicitLayers`
	- `HKEY_CURRENT_USER\SOFTWARE\Khronos\Vulkan\ExplicitLayers`.
3. Delete the entry that points to the non-existent JSON file and restart your program.

## Getting Started with the Ray Tracing Demo

The `src/` directory contains a minimalistic interactive ray tracing demo that showcases hardware-accelerated ray tracing using the LongMarch framework. This demo features a scene-based architecture with entity management, interactive camera controls, and an ImGui-based inspection interface.

In your own project, you could either start from this demo or build from scratch. You could modify any file in the `src/` directory to fit your needs.

### Project Structure

```
src/
├── main.cpp              # Application entry point
├── app.h/app.cpp         # Main application class with rendering loop
├── Scene.h/Scene.cpp     # Scene manager (TLAS, materials buffer)
├── Entity.h/Entity.cpp   # Entity class (mesh, BLAS, transform)
├── Film.h/Film.cpp       # Film class for progressive accumulation
├── Material.h            # Material structure for PBR properties
└── shaders/
    └── shader.hlsl       # Ray tracing shaders (raygen, miss, closest hit)
```

### Key Features

#### 1. Scene-Based Architecture
- **Scene Management**: The `Scene` class manages multiple entities and builds the Top-Level Acceleration Structure (TLAS)
- **Entity System**: Each `Entity` contains a mesh (loaded from `.obj` files), a material, and a transform matrix
- **Materials**: Simple PBR materials with base color, roughness, and metallic properties

#### 2. Interactive Camera Controls
The demo supports two modes:
- **Camera Mode** (right-click to enable):
  - `W/A/S/D` - Move forward/left/backward/right
  - `Space/Shift` - Move up/down
  - Mouse - Look around (cursor hidden)
  
- **Inspection Mode** (right-click to disable camera):
  - Mouse - Hover over entities to highlight them
  - Left-click - Select entity for detailed inspection
  - UI panels display camera, scene, and entity information

#### 3. Entity Highlighting and Selection
- **Pixel-Perfect Picking**: Uses a GPU-rendered entity ID buffer for accurate entity detection under the cursor
- **Hover Highlighting**: Entities glow yellow when the cursor hovers over them
- **Click Selection**: Left-click on an entity to select it and view details in the right panel

#### 4. Progressive Accumulation (Film Class)
- **Automatic Accumulation**: When camera is stationary (camera mode disabled), samples accumulate over time
- **High-Quality Rendering**: Progressive refinement produces noise-free images with more samples
- **Smart Reset**: Accumulation automatically resets when camera movement stops
- **Real-time Feedback**: Sample count displayed in UI shows accumulation progress

#### 5. Pixel Inspector
- **Real-time Color Sampling**: Shows RGB values of the pixel under the cursor
- **Original Color Display**: Values shown are before highlighting is applied (matches saved screenshots)
- **Multiple Formats**: Both normalized float (0.0-1.0) and 8-bit (0-255) values
- **Color Preview**: Visual color swatch shows the exact pixel color
- **Mouse Position**: Displays current cursor coordinates

#### 6. Screenshot Capture
- **Ctrl+S Shortcut**: Save accumulated output as PNG image
- **Automatic Naming**: Timestamped filenames (e.g., `screenshot_20251101_225009.png`)
- **Full Path Logging**: Console shows complete absolute path where image is saved
- **Pure Rendering**: Saved images exclude UI overlays and hover highlights
- **High Quality**: Captures the fully accumulated, noise-free render

#### 7. ImGui Interface
Two non-collapsible panels appear in inspection mode:
- **Left Panel** (Scene Information):
  - Camera position, direction, yaw, pitch
  - Speed and sensitivity settings
  - Entity count, material count, total triangles
  - Hovered and selected entity IDs
  - **Pixel Inspector**: Mouse position and RGB color values
  - Render information (resolution, backend, device)
  - Accumulation status and sample count
  - Controls hint
  
- **Right Panel** (Entity Inspector):
  - Dropdown to select any entity
  - Transform information (position, scale)
  - Material properties (base color, roughness, metallic)
  - Mesh statistics (triangles, vertices, indices)
  - BLAS build status

### How to Use

1. **Build and Run**:
   ```bash
   # In Visual Studio, select target: ShortMarchDemo.exe
   # Press F5 to build and run
   ```

2. **Navigate the Scene**:
   - Start in inspection mode (cursor visible)
   - Right-click to enable camera mode and fly around
   - Right-click again to return to inspection mode

3. **Inspect Entities**:
   - Move cursor over objects to see them highlight in yellow
   - Left-click to select an entity
   - View detailed information in the right panel
   - Or use the dropdown menu to select entities manually

4. **Inspect Pixels**:
   - Hover over any part of the rendered image
   - View RGB color values in the Pixel Inspector section
   - Values shown are the original rendered colors (before highlighting)

5. **Hide UI** (inspection mode only):
   - Hold **Tab** key to temporarily hide all UI panels
   - Useful for taking clean screenshots or viewing full render

6. **Save Screenshots**:
   - Press **Ctrl+S** to save the current accumulated output as PNG
   - Images saved with timestamp in filename
   - Console shows full path where image is saved
   - Saved images are clean (no UI, no highlights)

### Code Architecture

#### Application Class (`app.h/app.cpp`)
The main application class manages:
- Graphics core initialization (D3D12 or Vulkan)
- Window creation and event handling
- Camera state and controls
- Scene rendering and entity interaction
- ImGui interface rendering

Key methods:
- `OnInit()` - Initialize graphics, create scene, load entities
- `OnUpdate()` - Process input, update hover detection, upload GPU buffers
- `OnRender()` - Execute ray tracing, apply post-process highlighting, render ImGui overlays
- `OnClose()` - Clean up resources
- `UpdateHoveredEntity()` - GPU-based entity ID and pixel color readback for accurate picking
- `ApplyHoverHighlight()` - Post-process highlighting applied after accumulation
- `SaveAccumulatedOutput()` - Save clean accumulated render to PNG file

#### Scene Class (`Scene.h/Scene.cpp`)
Manages the scene graph:
- `AddEntity()` - Add entities to the scene
- `BuildAccelerationStructures()` - Build TLAS from all entity BLAS
- `UpdateMaterialsBuffer()` - Upload materials to GPU
- `GetTLAS()` - Get the acceleration structure for rendering

#### Entity Class (`Entity.h/Entity.cpp`)
Represents individual objects:
- `LoadMesh()` - Load geometry from `.obj` files
- `BuildBLAS()` - Create Bottom-Level Acceleration Structure
- Material and transform properties

#### Film Class (`Film.h/Film.cpp`)
Manages progressive sample accumulation:
- `Reset()` - Clear accumulated samples (called when camera stops moving)
- `IncrementSampleCount()` - Track the number of accumulated samples
- `DevelopToOutput()` - Average accumulated colors and output final image
- `Resize()` - Handle window resize events
- Internal buffers for accumulated color and sample counts

#### Shader (`shaders/shader.hlsl`)
HLSL ray tracing shaders:
- `RayGenMain` - Generate primary rays from camera, accumulate samples to film buffers, write entity IDs
- `MissMain` - Sky gradient for missed rays
- `ClosestHitMain` - Shading with material properties (highlighting done in post-process)
- Writes to multiple outputs: color, entity ID, and accumulation buffers

### Adding New Entities

To add new objects to the scene, edit `Application::OnInit()` in `app.cpp`:

```cpp
// Example: Add a new red sphere
auto red_sphere = std::make_shared<Entity>(
    "meshes/preview_sphere.obj",                    // Mesh path
    Material(glm::vec3(1.0f, 0.0f, 0.0f), 0.3f, 0.0f),  // Red, smooth, non-metallic
    glm::translate(glm::mat4(1.0f), glm::vec3(3.0f, 1.0f, 0.0f))  // Position
);
scene_->AddEntity(red_sphere);
```

After adding entities, remember to call `scene_->BuildAccelerationStructures()`.

### Customizing Materials

Materials use a simple PBR model:
```cpp
Material(
    glm::vec3(r, g, b),  // Base color (0.0 to 1.0)
    roughness,            // Surface roughness (0.0 = smooth, 1.0 = rough)
    metallic              // Metallic factor (0.0 = dielectric, 1.0 = metal)
);
```

### Technical Details

- **Acceleration Structures**: Uses hardware ray tracing with BLAS per entity and a single TLAS
- **Resource Bindings**:
  - Space 0: Acceleration Structure (TLAS)
  - Space 1: Output image (UAV) - immediate rendering output
  - Space 2: Camera info (constant buffer)
  - Space 3: Materials (structured buffer)
  - Space 4: Hover info (constant buffer)
  - Space 5: Entity ID output (UAV) - for pixel-perfect entity picking
  - Space 6: Accumulated color (UAV) - progressive accumulation buffer
  - Space 7: Accumulated samples (UAV) - sample count per pixel
- **Dual Output Mode**: 
  - Camera enabled: Shows immediate render output from space1
  - Camera disabled: Shows accumulated/averaged output for progressive refinement
- **Entity Picking**: Uses GPU-rendered ID buffer (space5) for pixel-perfect cursor-based entity selection
- **Post-Process Highlighting**: Hover highlights applied after accumulation, ensuring clean saved screenshots

### Keyboard Shortcuts

| Key Combination | Action | Mode |
|----------------|--------|------|
| **Right Click** | Toggle camera mode on/off | Any |
| **W/A/S/D** | Move camera forward/left/backward/right | Camera mode |
| **Space** | Move camera up | Camera mode |
| **Shift** | Move camera down | Camera mode |
| **Mouse** | Look around | Camera mode |
| **Left Click** | Select hovered entity | Inspection mode |
| **Tab** (hold) | Hide UI panels | Inspection mode |
| **Ctrl+S** | Save screenshot as PNG | Inspection mode |

### Performance Considerations

- **GPU Readback**: Entity ID and pixel color picking use synchronous GPU readback which may cause minor stalls
- **CPU-side Film Development**: The `DevelopToOutput()` method currently runs on CPU; consider implementing a compute shader for better performance
- **CPU-side Post-Highlighting**: The `ApplyHoverHighlight()` method downloads and uploads full images each frame when hovering
- **Sample Accumulation**: Accumulation happens in the shader every frame; when camera is moving, these writes are unused overhead

### Known Limitations

- **Simple Lighting**: Placeholder normal (up vector) for diffuse shading
- **No Anti-aliasing**: Single sample per pixel per frame (can be improved with jittered sampling)
- **Static Scenes**: Animation requires manual `UpdateInstances()` calls
- **Single Window**: ImGui context supports only one window at a time
- **No Tone Mapping**: Accumulated colors are directly averaged without tone mapping or exposure control
- **Performance Overhead**: Post-process highlighting and pixel inspector use full-image GPU readbacks

## 实现正确 Path Tracing 的要点（简短清单）

以下是实现 “可收敛、无小黑点、物理正确” path tracer 的关键步骤与优先级建议：

1. 高质量随机数 / 采样策略
   - 使用高质量 RNG（PCG / xorshift128+ / Sobol + Owen scrambling）避免周期性噪点。
   - 对每帧做像素级 jitter（亚像素抖动）和样本维度分层（stratified）或低偏差序列（蓝噪 / Sobol）。

2. 累积与显示
   - 在 shader 中累积样本并显示“累积平均值”，而不是只展示当前样本；这样逐帧会稳定收敛，明显减少黑点视觉感受。
   - 在相机移动或场景变化时重置累积（Film::Reset）。

3. 正确的几何/着色法线
   - 在 ClosestHit/HitRecord 中从顶点缓冲读取并按重心插值顶点法线（shading normal），使用几何法线计算 front_face 并保证一致性。
   - 如果不能访问顶点缓冲，提供健壮的回退法线估算；但长期方案应保证顶点访问可用。

4. 重要性采样（急需）
   - 漫反射：余弦加权半球采样（已经实现）。
   - 镜面/粗糙金属：GGX / VNDF 重要性采样（显著提升高光和金属区域收敛速度）。
   - 对发光体和环境使用预过滤/采样 CDF + MIS（Multiple Importance Sampling）。

5. 能量守恒与权重修正
   - 在采样与权重处确保基于 pdf 的重要性采样修正，维护能量守恒与无偏估计。
   - 俄罗斯轮盘（Russian roulette）在合理 bounce 后启用并用 throughput 作为基准。

6. 发光体与直接光
   - 将发光体（area lights / point / directional）作为显式采样源并配合 MIS，避免通过纯路径追踪慢收敛的直接光估计。
   - 对环境贴图做重要性采样（预计算 CDF）。

7. 材质与 BRDF 完整实现
   - 移植并验证 Disney/Principled BRDF（含 clearcoat, sheen, transmission），并保持与 CPU 侧 Material 结构一致的内存布局。
   - 注意 StructuredBuffer 中的对齐与 padding。

8. 结构化调试与收敛策略
   - 使用小场景与已知参考图对比（例如 Lambert 球 + point light）验证每一步改动。
   - 增加样本数、增加 bounce，或使用 denoiser（例如 OptiX/Intel/OpenImageDenoise）做后处理。

9. 性能与资源绑定
   - 确保顶点/索引/材质缓冲的绑定正确（shader 与 CPU 端布局一致）；未绑定会导致崩溃（你之前的错误堆栈即表明未绑定顶点缓冲）。  
   - 在 C++ 端打印/验证 shader resource 绑定状态（assert 或 debug marker）。

优先级建议（短期 -> 中期 -> 长期）：
- 短期：启用 jitter + 输出累积平均；修复 RNG；确保顶点缓冲绑定或使用稳健回退（避免崩溃）。  
- 中期：实现顶点法线插值（从缓冲读取）、GGX/VNDF 重要性采样、发光体直接采样 + MIS。  
- 长期：多通道（spectral / chromatic）采样优化、变分采样/蓝噪序列、去噪器集成与更复杂的材质模型。

如果你愿意，我可以：
- 帮你把 GLSL 中的 SampleGgxVndfAnisotropic / SampleDisneyBRDF / ComposeHitRecord 等直接翻译成 HLSL 版本（需要你确认顶点/索引缓冲在 D3D12/Vulkan 端如何绑定与布局）。  
- 或者先帮你做一版“顶点缓冲安全”的 HLSL：如果顶点缓冲已绑定则使用真实插值，否则回退到估算法线（当前实现类似）。
