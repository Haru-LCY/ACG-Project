# Advanced Computer Graphics 2025 - Project Requirements

## Core Components

### • Base (Basic)
- Implement a path tracing algorithm that correctly handles diffuse and specular materials :white_check_mark:

### • Scene Creation (Basic, +1pt for tidiness and attractiveness)
- Build a custom scene with aesthetic considerations
- Use geometry created from scratch or found online (with proper source credit)

### • Acceleration Structure (Basic, +2pts for Surface Area Heuristic or advanced algorithm)
- Implement an acceleration structure such as BVH (Bounding Volume Hierarchy)
- *Note: Not required for hardware-based renderers (built-in acceleration)*

## Advanced Features

### • Material (Choose one)
- Transmissive material (Basic)
- **Principled BSDF (2pts)**
- **Multi-layer material (2pts)**
- **Rendering of fur, hair, skin, etc. (2pts)**

### • Texture (Choose one or more)
- Color texture (Basic)
- **Normal map, height map, attribute map, or functional texture mapping (1pt each, up to 2pts)**
- **Implement an adaptive mipmap algorithm (2pts)**

### • Importance Sampling (2pts)
- Use advanced sampling algorithms for path tracing
- Importance sampling with Russian Roulette
- Multiple importance sampling

### • Volumetric Rendering (Choose one or more)
- **Subsurface scattering (2pts)**
- Homogeneous volume rendering (1pt)
- Inhomogeneous volume rendering (1pt)
- Channel-independent subsurface scattering (1pt)
- Volumetric emission (1pt)
- **Volumetric alpha shadow (2pts)**

### • Special Visual Effects (Choose one or more)
- Motion blur, depth of field (Basic)
- Alpha shadow (Basic)
- **Cartoon style rendering (2pts)**
- **Chromatic dispersion (2pts)**

### • Lighting (Choose one)
- Point light and area light (Basic)
- **Environment lighting with HDR, such as skybox (2pts)**

### • Anti-aliasing (Basic)
- Implement an anti-aliasing algorithm

### • Simulation-based content creation (Up to 2pts)


# Keyboard Shortcuts

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


# Project Structure

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

# Code Architecture

## Application Class (`app.h/app.cpp`)
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

## Scene Class (`Scene.h/Scene.cpp`)
Manages the scene graph:
- `AddEntity()` - Add entities to the scene
- `BuildAccelerationStructures()` - Build TLAS from all entity BLAS
- `UpdateMaterialsBuffer()` - Upload materials to GPU
- `GetTLAS()` - Get the acceleration structure for rendering

## Entity Class (`Entity.h/Entity.cpp`)
Represents individual objects:
- `LoadMesh()` - Load geometry from `.obj` files
- `BuildBLAS()` - Create Bottom-Level Acceleration Structure
- Material and transform properties

## Film Class (`Film.h/Film.cpp`)
Manages progressive sample accumulation:
- `Reset()` - Clear accumulated samples (called when camera stops moving)
- `IncrementSampleCount()` - Track the number of accumulated samples
- `DevelopToOutput()` - Average accumulated colors and output final image
- `Resize()` - Handle window resize events
- Internal buffers for accumulated color and sample counts

## Shader (`shaders/shader.hlsl`)
HLSL ray tracing shaders:
- `RayGenMain` - Generate primary rays from camera, accumulate samples to film buffers, write entity IDs
- `MissMain` - Sky gradient for missed rays
- `ClosestHitMain` - Shading with material properties (highlighting done in post-process)
- Writes to multiple outputs: color, entity ID, and accumulation buffers

## Adding New Entities

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

## Customizing Materials

Materials use a simple PBR model:
```cpp
Material(
    glm::vec3(r, g, b),  // Base color (0.0 to 1.0)
    roughness,            // Surface roughness (0.0 = smooth, 1.0 = rough)
    metallic              // Metallic factor (0.0 = dielectric, 1.0 = metal)
);
```

