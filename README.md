# Advanced Computer Graphics 2025 - Chunyu Liu and Zhengwei Feng

How to Build : Open the directory in the Microsoft Visual Studio and use cmake to build the project.

Then run the ShortMarchDemo.exe to start the application.

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


# Git Branches

This project contains multiple branches, each showcasing different scenes and rendering features:

## Main Scene Branches

- **main** - Robot scene featuring a "Terminator" character with cartoon rendering style
- **scene** - Staircase scene demonstrating rendering of complex geometric structures
- **demo** - Tropical island scene showcasing large-scale open-world rendering capabilities
- **volumetric-show** - Volumetric rendering scene demonstrating participating media and volume effects
- **height-map-switch** - Scene demonstrating normal map and height map switching for detail texture comparison

## Development Branches

The following branches document technical exploration and experimentation during development:
- **NO-BVH** - Experimental branch without BVH acceleration structure
- **kdt1** / **kdt2** - KD-Tree acceleration structure implementation attempts
- **try-fix** - Bug fixes and debugging branch

# Project Structure

```
src/
├── main.cpp              # Application entry point
├── app.h/app.cpp         # Main application class with rendering loop
├── Scene.h/Scene.cpp     # Scene manager (TLAS, materials buffer)
├── Entity.h/Entity.cpp   # Entity class (mesh, BLAS, transform)
├── Film.h/Film.cpp       # Film class for progressive accumulation
├── Material.h            # Material structure (Principled BSDF)
└── shaders/              # Ray tracing shaders
    ├── raygen.hlsl       # Ray generation shader
    ├── raytracing.hlsl   # Ray tracing pipeline
    ├── bsdf.hlsl         # BSDF evaluation functions
    ├── lighting.hlsl     # Lighting calculations
    ├── geometry.hlsl     # Geometry utilities
    ├── normal_map.hlsl   # Normal mapping
    ├── skybox.hlsl       # Skybox rendering
    ├── motion_blur.hlsl  # Motion blur effects
    ├── msaa.hlsl         # Multi-sample anti-aliasing
    ├── common.hlsl       # Common definitions
    └── rng.hlsl          # Random number generation
```

# Code Architecture

The project uses a D3D12/Vulkan-based ray tracing rendering architecture:

- **Application** (`app.h/app.cpp`) - Manages graphics core initialization, window events, camera controls, scene rendering, and ImGui interface. Supports features like cartoon shading, motion blur, MSAA, and progressive rendering.
- **Scene** (`Scene.h/Scene.cpp`) - Manages the scene graph, builds TLAS (Top-Level Acceleration Structure), uploads material buffers, and handles entity offsets for global buffers.
- **Entity** (`Entity.h/Entity.cpp`) - Represents objects in the scene with mesh data, BLAS (Bottom-Level Acceleration Structure), transform matrices, and optional texture/normal map support.
- **Film** (`Film.h/Film.cpp`) - Manages progressive sample accumulation for denoising and high-quality rendering when the camera is stationary.
- **Material** (`Material.h`) - Implements Disney's Principled BSDF model with parameters including base color, roughness, metallic, specular, transmission, subsurface scattering, emission, and texture mapping.
- **Shaders** (`shaders/*.hlsl`) - HLSL ray tracing shaders including RayGen, Miss, ClosestHit shaders, BSDF evaluation, lighting calculations, and various post-processing effects.

## Adding New Entities

To add new objects to the scene, edit `Application::OnInit()` in `app.cpp`:

```cpp
auto entity = std::make_shared<Entity>(
    "meshes/model.obj",                              // Mesh path
    Material(glm::vec3(1.0f, 0.0f, 0.0f), 0.3f, 0.0f),  // Material
    glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 0.0f, 0.0f)),  // Transform
    "textures/diffuse.png",                          // Optional texture path
    "textures/normal.png"                            // Optional normal map path
);
scene_->AddEntity(entity);
scene_->BuildAccelerationStructures();
```

## Material Parameters

Materials use Disney's Principled BSDF model with extensive parameters:

```cpp
Material(
    glm::vec3(r, g, b),  // Base color (0.0 to 1.0)
    roughness,            // Surface roughness (0.0 = smooth, 1.0 = rough)
    metallic,             // Metallic factor (0.0 = dielectric, 1.0 = metal)
    specular,             // Specular intensity (0.0 to 1.0)
    specular_tint,        // Specular tint (0.0 to 1.0)
    // ... and many more parameters for advanced material properties
);
```

See `Material.h` for the complete list of material parameters including transmission, subsurface scattering, clearcoat, sheen, and emission properties.


