#include "app.h"
#include "Material.h"
#include "Entity.h"

#include "glm/gtc/matrix_transform.hpp"
#include "imgui.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <chrono>
#include <iomanip>
#include <sstream>
#include <filesystem>

namespace {
#include "built_in_shaders.inl"
}

// 初始化天空盒（根据USE_HDR_SKYBOX开关决定使用HDR或程序化天空）
// 功能：尝试加载HDR环境贴图，失败则使用程序化天空
void Application::InitializeSkybox() {
    if (USE_HDR_SKYBOX) {
        // 尝试加载 HDR 环境贴图
        std::string full_path = grassland::FindAssetFile(HDR_SKYBOX_PATH);
        
        if (grassland::graphics::LoadImageFromFile(core_.get(), full_path, &environment_map_) == 0) {
            grassland::LogInfo("Loaded HDR environment map: {} ({}x{})", 
                               HDR_SKYBOX_PATH,
                               environment_map_->Extent().width,
                               environment_map_->Extent().height);
            skybox_info_.has_environment_map = 1.0f;
            return;
        }
        
        grassland::LogWarning("Failed to load HDR skybox from: {}, using procedural sky", HDR_SKYBOX_PATH);
    }
    
    // 使用程序化天空
    CreateDefaultEnvironmentMap();
    skybox_info_.has_environment_map = 0.0f;
    grassland::LogInfo("Using procedural sky");
}

// 创建默认的后备环境贴图（简单的渐变天空）
// 功能：生成一个64x32的渐变天空纹理，从天顶到地平线再到地面
void Application::CreateDefaultEnvironmentMap() {
    const int width = 64;
    const int height = 32;
    std::vector<float> default_data(width * height * 4);
    
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            int idx = (y * width + x) * 4;
            
            // 计算垂直位置 (0 = 底部/地面, 1 = 顶部/天顶)
            float v = 1.0f - (float)y / (float)(height - 1);
            
            // 简单的渐变天空
            glm::vec3 color;
            if (v > 0.5f) {
                // 天空部分: 从地平线到天顶
                float t = (v - 0.5f) * 2.0f;
                color = glm::mix(skybox_info_.horizon_color, skybox_info_.zenith_color, t);
            } else {
                // 地面部分: 从地平线到地面
                float t = (0.5f - v) * 2.0f;
                color = glm::mix(skybox_info_.horizon_color, skybox_info_.ground_color, t);
            }
            
            default_data[idx + 0] = color.r;
            default_data[idx + 1] = color.g;
            default_data[idx + 2] = color.b;
            default_data[idx + 3] = 1.0f;
        }
    }
    
    // 创建 GPU 纹理
    core_->CreateImage(width, height, 
                      grassland::graphics::IMAGE_FORMAT_R32G32B32A32_SFLOAT,
                      &environment_map_);
    environment_map_->UploadData(default_data.data());
    
    grassland::LogInfo("Created default environment map ({}x{})", width, height);
}

// 构造函数：创建应用程序实例
// api: 图形API后端（D3D12或Vulkan）
Application::Application(grassland::graphics::BackendAPI api) {
    // 创建图形核心对象
    grassland::graphics::CreateCore(api, grassland::graphics::Core::Settings{}, &core_);
    // 自动选择逻辑设备
    core_->InitializeLogicalDeviceAutoSelect(true);

    // 记录设备信息
    grassland::LogInfo("Device Name: {}", core_->DeviceName());
    grassland::LogInfo("- Ray Tracing Support: {}", core_->DeviceRayTracingSupport());
}

// 析构函数：清理资源
Application::~Application() {
    core_.reset();
}

// 处理键盘输入事件
// 功能：直接轮询键盘状态，确保即使ImGui激活时也能工作
// 处理WASD移动、Space/Shift上下移动、Tab隐藏UI、Ctrl+S保存截图等
void Application::ProcessInput() {
    // Get GLFW window handle
    GLFWwindow* glfw_window = window_->GLFWWindow();
    
    // Check if this window has focus - only process input for focused window
    if (glfwGetWindowAttrib(glfw_window, GLFW_FOCUSED) == GLFW_FALSE) {
        return;
    }

    // Tab key to toggle UI visibility (only in inspection mode)
    if (!camera_enabled_) {
        ui_hidden_ = (glfwGetKey(glfw_window, GLFW_KEY_TAB) == GLFW_PRESS);
    }
    
    // Ctrl+S to save accumulated output (only in inspection mode)
    static bool ctrl_s_was_pressed = false;
    bool ctrl_pressed = (glfwGetKey(glfw_window, GLFW_KEY_LEFT_CONTROL) == GLFW_PRESS || 
                        glfwGetKey(glfw_window, GLFW_KEY_RIGHT_CONTROL) == GLFW_PRESS);
    bool s_pressed = (glfwGetKey(glfw_window, GLFW_KEY_S) == GLFW_PRESS);
    bool ctrl_s_pressed = ctrl_pressed && s_pressed;
    
    if (ctrl_s_pressed && !ctrl_s_was_pressed && !camera_enabled_) {
        // Generate filename with timestamp
        auto now = std::chrono::system_clock::now();
        auto time_t = std::chrono::system_clock::to_time_t(now);
        std::tm tm;
        localtime_s(&tm, &time_t);
        
        std::ostringstream filename;
        filename << "screenshot_" 
                 << std::put_time(&tm, "%Y%m%d_%H%M%S")
                 << ".png";
        
        SaveAccumulatedOutput(filename.str());
    }
    ctrl_s_was_pressed = ctrl_s_pressed;
    
    // Only process camera movement if camera is enabled
    if (!camera_enabled_) {
        return;
    }

    // Poll key states directly
    // Move forward
    if (glfwGetKey(glfw_window, GLFW_KEY_W) == GLFW_PRESS) {
        camera_pos_ += camera_speed_ * camera_front_;
    }
    // Move backward
    if (glfwGetKey(glfw_window, GLFW_KEY_S) == GLFW_PRESS) {
        camera_pos_ -= camera_speed_ * camera_front_;
    }
    // Strafe left
    if (glfwGetKey(glfw_window, GLFW_KEY_A) == GLFW_PRESS) {
        camera_pos_ -= glm::normalize(glm::cross(camera_front_, camera_up_)) * camera_speed_;
    }
    // Strafe right
    if (glfwGetKey(glfw_window, GLFW_KEY_D) == GLFW_PRESS) {
        camera_pos_ += glm::normalize(glm::cross(camera_front_, camera_up_)) * camera_speed_;
    }
    // Move up (Space)
    if (glfwGetKey(glfw_window, GLFW_KEY_SPACE) == GLFW_PRESS) {
        camera_pos_ += camera_speed_ * camera_up_;
    }
    // Move down (Shift)
    if (glfwGetKey(glfw_window, GLFW_KEY_LEFT_SHIFT) == GLFW_PRESS || 
        glfwGetKey(glfw_window, GLFW_KEY_RIGHT_SHIFT) == GLFW_PRESS) {
        camera_pos_ -= camera_speed_ * camera_up_;
    }
}

// 鼠标移动事件处理函数
// xpos, ypos: 鼠标位置（屏幕坐标）
// 功能：更新鼠标位置，处理相机视角旋转（如果相机启用）
void Application::OnMouseMove(double xpos, double ypos) {
    // Always store mouse position for hover detection (even if ImGui wants input)
    mouse_x_ = xpos;
    mouse_y_ = ypos;

    // Only process camera look if camera is enabled
    if (!camera_enabled_) {
        return;
    }

    if (first_mouse_) {
        last_x_ = (float)xpos;
        last_y_ = (float)ypos;
        first_mouse_ = false;
        return;
    }

    float xoffset = (float)xpos - last_x_;
    float yoffset = last_y_ - (float)ypos; // Reversed since y-coordinates go from bottom to top
    last_x_ = (float)xpos;
    last_y_ = (float)ypos;

    xoffset *= mouse_sensitivity_;
    yoffset *= mouse_sensitivity_;

    yaw_ += xoffset;
    pitch_ += yoffset;

    // Constrain pitch to avoid flipping
    if (pitch_ > 89.0f)
        pitch_ = 89.0f;
    if (pitch_ < -89.0f)
        pitch_ = -89.0f;

    // Recalculate the camera_front_ vector
    glm::vec3 front;
    front.x = cos(glm::radians(yaw_)) * cos(glm::radians(pitch_));
    front.y = sin(glm::radians(pitch_));
    front.z = sin(glm::radians(yaw_)) * cos(glm::radians(pitch_));
    camera_front_ = glm::normalize(front);
}

// 鼠标按钮事件处理函数
// button: 按钮（0=左键，1=右键）
// action: 动作（1=按下）
// mods: 修饰键
// xpos, ypos: 鼠标位置
// 功能：左键选择实体，右键切换相机模式
void Application::OnMouseButton(int button, int action, int mods, double xpos, double ypos) {
    const int BUTTON_LEFT = 0;  // Left mouse button
    const int BUTTON_RIGHT = 1; // Right mouse button
    const int ACTION_PRESS = 1;

    // Left-click to select entity (only when camera is disabled)
    if (button == BUTTON_LEFT && action == ACTION_PRESS && !camera_enabled_) {
        // Select the currently hovered entity
        if (hovered_entity_id_ >= 0) {
            selected_entity_id_ = hovered_entity_id_;
            // Lock focus to this entity
            focused_entity_id_ = selected_entity_id_;
            if (film_) film_->Reset();
            grassland::LogInfo("Selected Entity #{} and focused on it", selected_entity_id_);
        } else {
            selected_entity_id_ = -1;
            // Do not change existing focus; keep focusing on previous entity until another is selected
            grassland::LogInfo("Deselected entity");
        }
    }

    if (button == BUTTON_RIGHT && action == ACTION_PRESS) {
        // Toggle camera mode
        camera_enabled_ = !camera_enabled_;
        
        GLFWwindow* glfw_window = window_->GLFWWindow();
        
        if (camera_enabled_) {
            // Entering camera mode - hide cursor and grab it
            glfwSetInputMode(glfw_window, GLFW_CURSOR, GLFW_CURSOR_DISABLED);
            first_mouse_ = true; // Reset to prevent jump
            grassland::LogInfo("Camera mode enabled - use WASD/Space/Shift to move, mouse to look");
        } else {
            // Exiting camera mode - show cursor
            glfwSetInputMode(glfw_window, GLFW_CURSOR, GLFW_CURSOR_NORMAL);
            grassland::LogInfo("Camera mode disabled - cursor visible, showing info overlay");
        }
    }
}



void Application::OnInit() {
    alive_ = true;
    core_->CreateWindowObject(1280, 720,
        ((core_->API() == grassland::graphics::BACKEND_API_VULKAN) ? "[Vulkan]" : "[D3D12]") +
        std::string(" Ray Tracing Scene Demo"),
        &window_);

    // Initialize ImGui for this window
    window_->InitImGui();

    // Register the mouse move event handler
    window_->MouseMoveEvent().RegisterCallback(
        [this](double xpos, double ypos) {
            this->OnMouseMove(xpos, ypos);
        }
    );
    // Register the mouse button event handler
    window_->MouseButtonEvent().RegisterCallback(
        [this](int button, int action, int mods, double xpos, double ypos) {
            this->OnMouseButton(button, action, mods, xpos, ypos);
        }
    );

    // Initialize camera as DISABLED to avoid cursor conflicts with multiple windows
    camera_enabled_ = false;
    last_camera_enabled_ = false;
    ui_hidden_ = false;
    hovered_entity_id_ = -1; // No entity hovered initially
    hovered_pixel_color_ = glm::vec4(0.0f); // No pixel color initially
    selected_entity_id_ = -1; // No entity selected initially
    mouse_x_ = 0.0;
    mouse_y_ = 0.0;
    // Don't grab cursor initially - user can right-click to enable camera mode

    // Create scene - Cornell Box scene
    scene_ = std::make_unique<Scene>(core_.get());

    // Cornell Box 原始尺寸约为 556x548.8x559.2，需要缩放以适应场景
    // 缩放因子 0.02 使其约为 11.12x10.98x11.18 单位（扩大一倍）
    // 同时需要平移使其中心位于原点附近
    glm::mat4 cornell_box_transform = glm::translate(glm::mat4(1.0f), glm::vec3(-5.56f, 0.0f, -5.6f))
                                    * glm::scale(glm::mat4(1.0f), glm::vec3(0.02f));

    // Add Cornell Box Floor (white)
    {
        auto floor = std::make_shared<Entity>(
            "meshes/cornell_box_floor.obj",
            Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),  // white
            cornell_box_transform
        );
        scene_->AddEntity(floor);
    }

    // Add Cornell Box Ceiling (white)
    {
        auto ceiling = std::make_shared<Entity>(
            "meshes/cornell_box_ceiling.obj",
            Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),  // white
            cornell_box_transform
        );
        scene_->AddEntity(ceiling);
    }

    // // Add Cornell Box Back Wall (white)
    // {
    //     auto back_wall = std::make_shared<Entity>(
    //         "meshes/cornell_box_back_wall.obj",
    //         Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),  // white
    //         cornell_box_transform
    //     );
    //     scene_->AddEntity(back_wall);
    // }

// BSDF mirrow with clear coat implement. backup
    // Add Cornell Box Front Wall (glass material with sakura texture, white color)
    {
        // Metallic mirror material with clear coat (softer parameters)
        Material front_wall_material(glm::vec3(1.0f, 1.0f, 1.0f), 0.05f, 0.9f);  // white, metallic mirror (roughness=0.05, metallic=0.9)
        front_wall_material.clearcoat = 0.8f;              // Moderate clear coat strength
        front_wall_material.clearcoat_roughness = 0.05f;   // Slightly rougher clear coat for softer reflection
        
        // Front wall dimensions: width=556, height=548.8 (in original coordinates)
        // After cornell_box_transform (scale 0.02): width=11.12, height=10.976
        // Cube is 2x2x2 unit cube, so scale factors: width=11.12/2=5.56, height=10.976/2=5.488, depth=0.1/2=0.05
        // Center position: x=(549.6+0)/2*0.02-5.56=-0.064, y=274.4*0.02=5.488, z=0*0.02-5.6=-5.6
        glm::mat4 front_wall_transform = glm::translate(glm::mat4(1.0f), glm::vec3(-0.064f, 5.488f, -5.6f))
                                       * glm::scale(glm::mat4(1.0f), glm::vec3(5.56f, 5.488f, 0.05f));  // Scale cube to match wall size
        
        auto front_wall = std::make_shared<Entity>(
            "meshes/cube.obj",
            front_wall_material,
            front_wall_transform
        );
        scene_->AddEntity(front_wall);
    }

    // Add Cornell Box Front Wall (white block material with height map)
    // {
    //     // White block material (high roughness, more diffuse reflection)
    //     Material front_wall_material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f);  // white, high roughness, non-metallic
    //     front_wall_material.height_scale = 0.1f;  // Enable height map with strong effect
        
    //     // Front wall dimensions: width=556, height=548.8 (in original coordinates)
    //     // After cornell_box_transform (scale 0.02): width=11.12, height=10.976
    //     // Cube is 2x2x2 unit cube, so scale factors: width=11.12/2=5.56, height=10.976/2=5.488, depth=0.1/2=0.05
    //     // Center position: x=(549.6+0)/2*0.02-5.56=-0.064, y=274.4*0.02=5.488, z=0*0.02-5.6=-5.6
    //     glm::mat4 front_wall_transform = glm::translate(glm::mat4(1.0f), glm::vec3(-0.064f, 5.488f, -5.6f))
    //                                    * glm::scale(glm::mat4(1.0f), glm::vec3(5.56f, 5.488f, 0.05f));  // Scale cube to match wall size
        
    //     auto front_wall = std::make_shared<Entity>(
    //         "meshes/cube.obj",
    //         front_wall_material,
    //         front_wall_transform,
    //         "",
    //         "textures/normal.png"
    //     );
    //     scene_->AddEntity(front_wall);
    // }

    {
        auto blue_cube = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.3f, 0.3f, 1.0f), 0.05f, 0.0f, 0.95f, 1.5f), // 蓝色玻璃：明显的蓝色色调
            // Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.3f, 0.9f),  // 白色基础,金属
            // 将蓝色玻璃往 x 轴靠外移动，更靠近摄像机位置
            glm::translate(glm::mat4(1.0f), glm::vec3(-2.0f, 2.0f, 4.0f))  // x从2.0改为3.5，更靠近相机
            // "textures/sakura.png"
        );
        blue_cube->SetVelocity(glm::vec3(1.0f, 0.0f, 0.0f));  // 向右移动的运动模糊
        scene_->AddEntity(blue_cube);
    }


    {
        // White base material with iiis texture
        auto white_cube = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),  // white base material (non-metallic, non-transparent)
            glm::translate(glm::mat4(1.0f), glm::vec3(2.0f, 1.0f, 4.0f)),
            "textures/iiis.png"  // Add iiis texture
        );
        white_cube->SetVelocity(glm::vec3(1.0f, 0.0f, 0.0f));  // 向右移动的运动模糊
        scene_->AddEntity(white_cube);
    }


    // Add Cornell Box Green Wall
    {
        auto green_wall = std::make_shared<Entity>(
            "meshes/cornell_box_green_wall.obj",
            Material(glm::vec3(0.0f, 1.0f, 0.0f), 0.8f, 0.0f),  // green
            cornell_box_transform
        );
        scene_->AddEntity(green_wall);
    }

    // Add Cornell Box Red Wall
    {
        auto red_wall = std::make_shared<Entity>(
            "meshes/cornell_box_red_wall.obj",
            Material(glm::vec3(1.0f, 0.0f, 0.0f), 0.8f, 0.0f),  // red
            cornell_box_transform
        );
        scene_->AddEntity(red_wall);
    }

    // Add Cornell Box Light (emissive white)
    {
        Material light_material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f);
        light_material.emission_color = glm::vec3(1.0f, 1.0f, 1.0f);
        light_material.emission_strength = 20.0f;  // Ka 20 20 20 from MTL
        
        auto light = std::make_shared<Entity>(
            "meshes/cornell_box_light.obj",
            light_material,
            cornell_box_transform
        );
        scene_->AddEntity(light);
    }

    // Add Cornell Box Short Block (white base material with tsinghua texture)
    {
        // Replace short_block with cube of same size, with tsinghua texture
        // Short block dimensions: width≈208, height=165, depth≈207 (in original coordinates)
        // After cornell_box_transform (scale 0.02): width≈4.16, height=3.3, depth≈4.14
        // Scale to 2x current size: width≈2.496, height=1.98, depth≈2.484
        // Adjust position so bottom surface aligns with floor (y=0), then move up 1 unit
        // Cube height = 1.98, so center should be at y = 1.98/2 + 1.0 = 1.99
        glm::mat4 cube_transform = glm::translate(glm::mat4(1.0f), glm::vec3(-1.84f, 1.99f, -2.23f))
                                  * glm::scale(glm::mat4(1.0f), glm::vec3(2.496f, 1.98f, 2.484f));  // Scale to 2x current size
        
        auto short_block = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),  // white, non-metallic base material
            cube_transform,
            "textures/tsinghua.png"  // Add tsinghua texture
        );
        // short_block->SetVelocity(glm::vec3(0.0f, 0.0f, 1.0f));  // 向 z 轴正方向移动的运动模糊
        scene_->AddEntity(short_block);
    }

    // {
    //     auto blue_cube = std::make_shared<Entity>(
    //         "meshes/cube.obj",
    //         Material(glm::vec3(0.3f, 0.3f, 1.0f), 0.05f, 0.0f, 0.95f, 1.5f), // 蓝色玻璃：明显的蓝色色调
    //         // Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.3f, 0.9f),  // 白色基础,金属
    //         // 将蓝色玻璃往 x 轴靠外移动，更靠近摄像机位置
    //         glm::translate(glm::mat4(1.0f), glm::vec3(3.5f, 1.0f, 10.0f)),  // x从2.0改为3.5，更靠近相机
    //         "textures/sakura.png"
    //     );
    //     blue_cube->SetVelocity(glm::vec3(1.0f, 0.0f, 0.0f));  // 向右移动的运动模糊
    //     scene_->AddEntity(blue_cube);
    // }




    // Add Cornell Box Tall Block (white) - replaced by flower
    // {
    //     auto tall_block = std::make_shared<Entity>(
    //         "meshes/cornell_box_tall_block.obj",
    //         Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),  // white
    //         cornell_box_transform
    //     );
    //     scene_->AddEntity(tall_block);
    // }

    // Add small flower asset from assets (scale 0.1) and rotate to stand upright
    // Positioned at tall_block location: center at (368.5, 165.0, 351.5) in original coordinates
    // After cornell_box_transform (scale 0.02, translate (-5.56, 0, -5.6)):
    // x: 368.5 * 0.02 - 5.56 = 1.81
    // y: 165.0 * 0.02 = 3.3
    // z: 351.5 * 0.02 - 5.6 = 1.43
    // {
    //     // Build a transform: translate * rotate * scale
    //     // Position at tall_block center, rotate to stand upright
    //     glm::mat4 flower_transform = glm::translate(glm::mat4(1.0f), glm::vec3(1.81f, 3.3f, 1.43f))
    //                               * glm::rotate(glm::mat4(1.0f), glm::radians(-90.0f), glm::vec3(1.0f, 0.0f, 0.0f))
    //                               * glm::scale(glm::mat4(1.0f), glm::vec3(0.1f));

    //     auto flower = std::make_shared<Entity>(
    //         "meshes/12973_anemone_flower_v1_l2.obj",
    //         // diffuse, non-metallic material
    //         Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),
    //         flower_transform,
    //         // use diffuse texture from the mesh's material if available
    //         "meshes/12973_anemone_flower_diff.jpg"
    //     );
    //     // keep static (no velocity) by default
    //     flower->SetVelocity(glm::vec3(0.0f, 0.0f, 0.0f));
    //     scene_->AddEntity(flower);
    // }

    // Build acceleration structures
    scene_->BuildAccelerationStructures();

    // Create film for accumulation
    film_ = std::make_unique<Film>(core_.get(), window_->GetWidth(), window_->GetHeight());

    core_->CreateBuffer(sizeof(CameraObject), grassland::graphics::BUFFER_TYPE_DYNAMIC, &camera_object_buffer_);
    
    // Create hover info buffer
    core_->CreateBuffer(sizeof(HoverInfo), grassland::graphics::BUFFER_TYPE_DYNAMIC, &hover_info_buffer_);
    HoverInfo initial_hover{};
    initial_hover.hovered_entity_id = -1;
    hover_info_buffer_->UploadData(&initial_hover, sizeof(HoverInfo));

    // 创建点光源缓冲区并初始化点光源
    // 初始化点光源数组（最多16个）
    point_lights_.resize(16);  // 预留16个点光源槽位
    
    // 删除所有之前的点光源（强度设为0）
    for (int i = 0; i < 16; ++i) {
        point_lights_[i].position = glm::vec3(0.0f);
        point_lights_[i].color = glm::vec3(1.0f);
        point_lights_[i].strength = 0.0f;  // 强度为0表示未激活
        point_lights_[i].radius = 0.0f;
    }
    
    // 在环境光顶部靠右位置添加一个明显的点光源
    // 环境光位置：area_lights_[0].position = (0.0f, 10.5f, 0.0f)
    // 点光源位置：顶部靠右，稍微偏前，强度较高以明显区别于环境光
    point_lights_[0].position = glm::vec3(3.5f, 10.5f, 2.0f);  // 顶部靠右，稍微偏前
    point_lights_[0].color = glm::vec3(1.0f, 0.95f, 0.9f);      // 稍微暖色调的白光
    point_lights_[0].strength = 2000.0f;                        // 高强度，明显区别于环境光
    point_lights_[0].radius = 0.15f;                            // 较小的半径，产生明显的高光
    
    // 创建并上传点光源缓冲区
    core_->CreateBuffer(sizeof(PointLight) * 16, grassland::graphics::BUFFER_TYPE_DYNAMIC, &point_lights_buffer_);
    point_lights_buffer_->UploadData(point_lights_.data(), sizeof(PointLight) * 16);
    grassland::LogInfo("Initialized {} point lights", 3);

    // 初始化面光源数组（最多8个）
    area_lights_.resize(8);
    // 配置主光源 - 天花板白光
    // Ceiling height: 548.8 * 0.02 = 10.976 (after cornell_box_transform scale)
    // Position should be near ceiling center, slightly below it
    area_lights_[0].position = glm::vec3(0.0f, 10.5f, 0.0f);      // 接近天花板（调整到正确位置）
    area_lights_[0].color = glm::vec3(1.0f, 1.0f, 1.0f);         // 白色
    area_lights_[0].strength = 0.0f;                            // 较强的主光源
    area_lights_[0].width = 6.0f;                                 // 扩大面积以匹配场景（从3.0改为6.0）
    area_lights_[0].height = 6.0f;                                // 扩大面积以匹配场景（从3.0改为6.0）
    area_lights_[0].direction = glm::normalize(glm::vec3(0.0f, -1.0f, 0.0f));  // 向下
    area_lights_[0].u_axis = glm::normalize(glm::vec3(1.0f, 0.0f, 0.0f));      // X轴
    area_lights_[0].v_axis = glm::normalize(glm::vec3(0.0f, 0.0f, 1.0f));      // Z轴
    area_lights_[0].pad1 = 0.0f;
    area_lights_[0].pad2 = 0.0f;
    
    // 配置左侧光
    area_lights_[1].position = glm::vec3(-4.9f, 2.0f, 0.0f);     // 靠近左墙
    area_lights_[1].color = glm::vec3(0.4f, 0.4f, 1.0f);         // 柔和蓝色
    area_lights_[1].strength = 0.0f;                             // 中等强度
    area_lights_[1].width = 0.5f;                                 // 窄条
    area_lights_[1].height = 2.5f;                                // 高条
    area_lights_[1].direction = glm::normalize(glm::vec3(1.0f, 0.0f, 0.0f));   // 向右
    area_lights_[1].u_axis = glm::normalize(glm::vec3(0.0f, 1.0f, 0.0f));      // Y轴
    area_lights_[1].v_axis = glm::normalize(glm::vec3(0.0f, 0.0f, 1.0f));      // Z轴
    area_lights_[1].pad1 = 0.0f;
    area_lights_[1].pad2 = 0.0f;
    
    // 配置右侧光
    area_lights_[2].position = glm::vec3(4.9f, 2.0f, 0.0f);      // 靠近右墙
    area_lights_[2].color = glm::vec3(1.0f, 0.6f, 0.4f);         // 暖橙色
    area_lights_[2].strength = 0.0f;                             // 中等强度
    area_lights_[2].width = 0.5f;                                 // 窄条
    area_lights_[2].height = 2.5f;                                // 高条
    area_lights_[2].direction = glm::normalize(glm::vec3(-1.0f, 0.0f, 0.0f));  // 向左
    area_lights_[2].u_axis = glm::normalize(glm::vec3(0.0f, 1.0f, 0.0f));      // Y轴
    area_lights_[2].v_axis = glm::normalize(glm::vec3(0.0f, 0.0f, 1.0f));      // Z轴
    area_lights_[2].pad1 = 0.0f;
    area_lights_[2].pad2 = 0.0f;
    
    // 其余光源强度设为0（未使用）
    for (int i = 3; i < 8; ++i) {
        area_lights_[i].position = glm::vec3(0.0f);
        area_lights_[i].color = glm::vec3(1.0f);
        area_lights_[i].strength = 0.0f;  // 强度为0表示未激活
        area_lights_[i].width = 0.0f;
        area_lights_[i].height = 0.0f;
        area_lights_[i].direction = glm::vec3(0.0f, -1.0f, 0.0f);
        area_lights_[i].u_axis = glm::vec3(1.0f, 0.0f, 0.0f);
        area_lights_[i].v_axis = glm::vec3(0.0f, 0.0f, 1.0f);
        area_lights_[i].pad1 = 0.0f;
        area_lights_[i].pad2 = 0.0f;
    }
    
    // 创建并上传面光源缓冲区
    core_->CreateBuffer(sizeof(AreaLight) * 8, grassland::graphics::BUFFER_TYPE_DYNAMIC, &area_lights_buffer_);
    area_lights_buffer_->UploadData(area_lights_.data(), sizeof(AreaLight) * 8);
    grassland::LogInfo("Initialized {} area lights", 3);

    // ==================== 初始化 Skybox / Environment Map ====================
    // 初始化 skybox 信息
    skybox_info_.zenith_color = glm::vec3(0.3f, 0.5f, 0.85f);    // 深蓝色天顶
    skybox_info_.horizon_color = glm::vec3(0.7f, 0.75f, 0.85f);  // 浅蓝色地平线
    skybox_info_.ground_color = glm::vec3(0.3f, 0.3f, 0.35f);    // 深灰色地面
    skybox_info_.has_environment_map = 1.0f;                       // 默认开启环境贴图
    skybox_info_.environment_intensity = 1.0f;                     // 默认强度
    skybox_info_.environment_rotation = 0.0f;                      // 无旋转
    
    // 太阳设置
    skybox_info_.sun_direction = glm::normalize(glm::vec3(0.5f, 0.8f, 0.3f));
    skybox_info_.sun_intensity = 0.0f;                             // 默认关闭太阳光
    skybox_info_.sun_color = glm::vec3(1.0f, 0.95f, 0.85f);       // 暖色阳光
    skybox_info_.sun_angular_radius = 0.00465f;                    // 约 0.53 度（真实太阳大小）
    
    // 创建 skybox info 缓冲区
    core_->CreateBuffer(sizeof(SkyboxInfo), grassland::graphics::BUFFER_TYPE_DYNAMIC, &skybox_info_buffer_);
    skybox_info_buffer_->UploadData(&skybox_info_, sizeof(SkyboxInfo));
    
    // 初始化 Skybox (根据 USE_HDR_SKYBOX 开关)
    InitializeSkybox();
    
    // 重新上传 skybox info (可能被 InitializeSkybox 修改)
    skybox_info_buffer_->UploadData(&skybox_info_, sizeof(SkyboxInfo));
    
    // 创建环境贴图采样器
    grassland::graphics::SamplerInfo env_sampler_info;
    env_sampler_info.min_filter = grassland::graphics::FILTER_MODE_LINEAR;
    env_sampler_info.mag_filter = grassland::graphics::FILTER_MODE_LINEAR;
    env_sampler_info.address_mode_u = grassland::graphics::ADDRESS_MODE_REPEAT;
    env_sampler_info.address_mode_v = grassland::graphics::ADDRESS_MODE_CLAMP_TO_EDGE;
    env_sampler_info.address_mode_w = grassland::graphics::ADDRESS_MODE_REPEAT;
    core_->CreateSampler(env_sampler_info, &environment_sampler_);

    // Initialize camera state member variables
    camera_pos_ = glm::vec3{ -0.3f, 2.1f, 10.2f }; // 展览馆内部视角
    camera_up_ = glm::vec3{ 0.0f, 1.0f, 0.0f }; // World up
    camera_speed_ = 0.05f; // 提升5倍速度（从0.01到0.05）

    // Initialize new mouse/view variables
    yaw_ = -111.6f; // 根据相机方向设置
    pitch_ = -12.5f;
    last_x_ = (float)window_->GetWidth() / 2.0f;
    last_y_ = (float)window_->GetHeight() / 2.0f;
    mouse_sensitivity_ = 0.1f;
    first_mouse_ = true;
    // Initialize hover stability variables
    hover_candidate_id_ = -2; // invalid
    hover_consistency_count_ = 0;
    hover_consistency_threshold_ = 2; // default 2 frames consistency
    
    // Initialize depth of field parameters
    aperture_ = 0.0f;        // 默认开启景深，这个值比较明显（可在UI调整）
    focus_distance_ = 6.0f;  // 默认焦距6米 -> focal plane at z=2 (camera z=8)
        samples_per_frame_ = 2;  // 每帧每像素多采样次数，默认为2，能显著降低闪烁
        focused_entity_id_ = -1; // no focus locked initially
    exposure_ = 0.25f;       // Default exposure multiplier (half of original 0.5f)
    lights_need_upload_ = false; // track if any light params changed
    
    // Initialize MSAA parameters
    msaa_mode_ = MSAA_MODE_4X;  // 默认使用 4x MSAA
    accumulated_frames_ = 0;    // 累积帧计数
    
    // Initialize Motion Blur parameters
    motion_blur_mode_ = 0;          // 默认关闭运动模糊
    motion_blur_intensity_ = 0.5f;  // 默认强度
    motion_blur_direction_ = glm::vec2(1.0f, 0.0f); // 默认水平方向

    // Calculate initial camera_front_ based on yaw and pitch
    glm::vec3 front;
    front.x = cos(glm::radians(yaw_)) * cos(glm::radians(pitch_));
    front.y = sin(glm::radians(pitch_));
    front.z = sin(glm::radians(yaw_)) * cos(glm::radians(pitch_));
    camera_front_ = glm::normalize(front);

    // Set initial camera buffer data
    CameraObject camera_object{};
    camera_object.screen_to_camera = glm::inverse(
        glm::perspective(glm::radians(60.0f), (float)window_->GetWidth() / (float)window_->GetHeight(), 0.1f, 10.0f));
    camera_object.camera_to_world =
        glm::inverse(glm::lookAt(camera_pos_, camera_pos_ + camera_front_, camera_up_));
    camera_object.aperture = aperture_;
    camera_object.focus_distance = focus_distance_;
    camera_object.samples_per_pixel = samples_per_frame_;
    camera_object.exposure = exposure_;
    camera_object.debug_mode = 0;
    camera_object.debug_point_index = 0;
    camera_object.msaa_mode = msaa_mode_;
    camera_object.accumulated_frames = accumulated_frames_;
    camera_object.motion_blur_mode = motion_blur_mode_;
    camera_object.motion_blur_intensity = motion_blur_intensity_;
    camera_object.motion_blur_direction = motion_blur_direction_;
    camera_object_buffer_->UploadData(&camera_object, sizeof(CameraObject));

    core_->CreateImage(window_->GetWidth(), window_->GetHeight(), grassland::graphics::IMAGE_FORMAT_R32G32B32A32_SFLOAT,
        &color_image_);
    
    // Create entity ID buffer for accurate picking (R32_SINT to store entity indices)
    core_->CreateImage(window_->GetWidth(), window_->GetHeight(), grassland::graphics::IMAGE_FORMAT_R32_SINT,
        &entity_id_image_);
    core_->CreateImage(window_->GetWidth(), window_->GetHeight(), grassland::graphics::IMAGE_FORMAT_R32_SFLOAT,
        &depth_image_);

    grassland::VirtualFileSystem shader_vfs = GetShaderVirtualFileSystem();
    core_->CreateShader(shader_vfs, "shaders/shader.hlsl", "RayGenMain", "lib_6_3", &raygen_shader_);
    core_->CreateShader(shader_vfs, "shaders/shader.hlsl", "MissMain", "lib_6_3", &miss_shader_);
    core_->CreateShader(shader_vfs, "shaders/shader.hlsl", "ClosestHitMain", "lib_6_3", &closest_hit_shader_);
    grassland::LogInfo("Shader compiled successfully");

    // Create texture sampler
    grassland::graphics::SamplerInfo sampler_info;
    sampler_info.min_filter = grassland::graphics::FILTER_MODE_LINEAR;
    sampler_info.mag_filter = grassland::graphics::FILTER_MODE_LINEAR;
    sampler_info.address_mode_u = grassland::graphics::ADDRESS_MODE_REPEAT;
    sampler_info.address_mode_v = grassland::graphics::ADDRESS_MODE_REPEAT;
    sampler_info.address_mode_w = grassland::graphics::ADDRESS_MODE_REPEAT;
    core_->CreateSampler(sampler_info, &texture_sampler_);
    
    core_->CreateRayTracingProgram(raygen_shader_.get(), miss_shader_.get(), closest_hit_shader_.get(), &program_);
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_ACCELERATION_STRUCTURE, 1);  // space0
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_WRITABLE_IMAGE, 1);          // space1 - color output
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_UNIFORM_BUFFER, 1);          // space2
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space3 - materials
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_UNIFORM_BUFFER, 1);          // space4 - hover info
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_WRITABLE_IMAGE, 1);          // space5 - entity ID output
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_WRITABLE_IMAGE, 1);          // space6 - accumulated color
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_WRITABLE_IMAGE, 1);          // space7 - accumulated samples
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space8 - point lights
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space9 - area lights
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_IMAGE, MAX_TEXTURES);        // space10 - texture array
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_SAMPLER, 1);                 // space11 - texture sampler
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_WRITABLE_IMAGE, 1);          // space12 - depth image
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space13 - reserved
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_UNIFORM_BUFFER, 1);          // space14 - reserved
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space15 - entity velocities (motion blur)
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_UNIFORM_BUFFER, 1);          // space16 - skybox info
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_IMAGE, 1);                   // space17 - environment map
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_SAMPLER, 1);                 // space18 - environment sampler
    // 全局几何缓冲区绑定
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space19 - global vertices
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space20 - global normals
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space21 - global texcoords
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space22 - global indices
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space23 - entity offsets
    program_->Finalize();
}

void Application::OnClose() {
    // Clean up graphics resources first
    program_.reset();
    raygen_shader_.reset();
    miss_shader_.reset();
    closest_hit_shader_.reset();

    scene_.reset();
    film_.reset();

    color_image_.reset();
    entity_id_image_.reset();
    camera_object_buffer_.reset();
    hover_info_buffer_.reset();
    point_lights_buffer_.reset();  // 清理点光源缓冲区
    area_lights_buffer_.reset();   // 清理面光源缓冲区
    texture_sampler_.reset();      // 清理纹理采样器
    depth_image_.reset(); // 清理深度图像
    
    // 清理 Skybox 资源
    skybox_info_buffer_.reset();
    environment_map_.reset();
    environment_sampler_.reset();
    
    // Don't call TerminateImGui - let the window destructor handle it
    // Just reset window which will clean everything up properly
    window_.reset();
}

// 更新鼠标悬停的实体
// 功能：从entity_id_image_读取鼠标位置下的实体ID，实现悬停检测
// 注意：仅在相机禁用时检测（光标可见时）
void Application::UpdateHoveredEntity() {
    // 仅在相机禁用时检测悬停（光标可见）
    if (camera_enabled_) {
        hovered_entity_id_ = -1;
        hovered_pixel_color_ = glm::vec4(0.0f);
        return;
    }

    // Get mouse position in pixel coordinates
    int x = static_cast<int>(mouse_x_);
    int y = static_cast<int>(mouse_y_);
    int width = window_->GetWidth();
    int height = window_->GetHeight();
    
    // Check bounds
    if (x < 0 || x >= width || y < 0 || y >= height) {
        hovered_entity_id_ = -1;
        hovered_pixel_color_ = glm::vec4(0.0f);
        return;
    }

    grassland::graphics::Offset2D offset{ x, y };
    grassland::graphics::Extent2D extent{ 1, 1 };
    
    // Read entity ID from the ID buffer at the mouse position
    // The entity_id_image_ stores the entity index (-1 for no entity)
    int32_t entity_id = -1;
    entity_id_image_->DownloadData(&entity_id, offset, extent);

    // Hover smoothing: update only if the same candidate appears consistently
    if (entity_id == hover_candidate_id_) {
        hover_consistency_count_++;
    } else {
        hover_candidate_id_ = entity_id;
        hover_consistency_count_ = 1;
    }
    if (hover_consistency_count_ >= hover_consistency_threshold_) {
        hovered_entity_id_ = hover_candidate_id_;
    }
    
    // Read pixel color from accumulated buffer (before highlighting is applied)
    // Note: This is a synchronous read which may cause a GPU stall
    // For better performance, consider using a readback buffer with a frame delay
    float accumulated_rgba[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    film_->GetAccumulatedColorImage()->DownloadData(accumulated_rgba, offset, extent);
    
    // Average by sample count to get final color (before highlighting)
    int sample_count = film_->GetSampleCount();
    if (sample_count > 0) {
        hovered_pixel_color_ = glm::vec4(
            accumulated_rgba[0] / static_cast<float>(sample_count),
            accumulated_rgba[1] / static_cast<float>(sample_count),
            accumulated_rgba[2] / static_cast<float>(sample_count),
            accumulated_rgba[3] / static_cast<float>(sample_count)
        );
    } else {
        hovered_pixel_color_ = glm::vec4(0.0f);
    }
    
    // Hover state is shown in the UI panels, no logging needed
}

// 更新应用程序状态（每帧调用）
// 功能：处理窗口关闭、处理输入、更新相机、检测相机移动、更新悬停实体、更新GPU缓冲区
void Application::OnUpdate() {
    // 检查窗口是否应该关闭
    if (window_->ShouldClose()) {
        window_->CloseWindow();
        alive_ = false;
        return;  // 关闭后立即退出更新
    }
    if (alive_) {
        // 处理键盘输入以移动相机
        ProcessInput();
        
        CameraObject current_camera_object{};
        current_camera_object.screen_to_camera = glm::inverse(
            glm::perspective(glm::radians(60.0f), (float)window_->GetWidth() / (float)window_->GetHeight(), 0.1f, 10.0f));
        current_camera_object.camera_to_world =
            glm::inverse(glm::lookAt(camera_pos_, camera_pos_ + camera_front_, camera_up_));
        
 
        bool camera_moved = false;
        if (has_prev_camera_) {
            if (MatrixChanged(current_camera_object.camera_to_world, prev_camera_to_world_) ||
                MatrixChanged(current_camera_object.screen_to_camera, prev_screen_to_camera_)) {
                camera_moved = true;
            }
        }
        
        // 更新历史记录为当前矩阵
        prev_camera_to_world_ = current_camera_object.camera_to_world;
        prev_screen_to_camera_ = current_camera_object.screen_to_camera;
        has_prev_camera_ = true;
        
        // 如果相机移动，清空累积缓冲区
        if (camera_moved && film_) {
            film_->Reset();  // Film::Reset() 负责清空 GPU 累积贴图
            accumulated_frames_ = 0;  // 重置累积帧计数
        }

        
        // Detect camera state change and reset accumulation if camera started moving
        if (camera_enabled_ != last_camera_enabled_) {
            if (camera_enabled_) {
                // Camera just got enabled - will be moving, so prepare for reset when it stops
            } else {
                // Camera just got disabled - reset accumulation for new stationary view
                film_->Reset();
                accumulated_frames_ = 0;  // 重置累积帧计数
            }
            last_camera_enabled_ = camera_enabled_;
        }
        
        // Update which entity is being hovered
        UpdateHoveredEntity();
        
        // Update hover info buffer
        HoverInfo hover_info{};
        hover_info.hovered_entity_id = hovered_entity_id_;
        hover_info_buffer_->UploadData(&hover_info, sizeof(HoverInfo));

        // --------------- 修改开始 ---------------
        // 上传当前帧的 CameraObject（使用上面计算的 current_camera_object）
        // 添加景深参数
        current_camera_object.aperture = aperture_;
        // If focus is locked to an entity, update focus_distance_ from that entity
        if (focused_entity_id_ >= 0 && focused_entity_id_ < (int)scene_->GetEntityCount()) {
            auto focusedEntity = scene_->GetEntities()[focused_entity_id_];
            if (focusedEntity) {
                glm::mat4 transform = focusedEntity->GetTransform();
                glm::vec3 entity_pos = glm::vec3(transform[3]);
                float forwardDist = glm::dot(entity_pos - camera_pos_, camera_front_);
                float dist = forwardDist > 0.001f ? forwardDist : glm::length(entity_pos - camera_pos_);
                focus_distance_ = dist;
            }
        }
        current_camera_object.focus_distance = focus_distance_;
        current_camera_object.samples_per_pixel = samples_per_frame_;
        current_camera_object.exposure = exposure_;
        current_camera_object.debug_mode = 0;
        current_camera_object.debug_point_index = 0;
        current_camera_object.msaa_mode = msaa_mode_;
        current_camera_object.accumulated_frames = accumulated_frames_;
        current_camera_object.motion_blur_mode = motion_blur_mode_;
        current_camera_object.motion_blur_intensity = motion_blur_intensity_;
        current_camera_object.motion_blur_direction = motion_blur_direction_;
        camera_object_buffer_->UploadData(&current_camera_object, sizeof(CameraObject));
        // --------------- 修改结束 ---------------


        // Optional: Animate entities
        // For now, entities are static. You can update their transforms and call:
        // scene_->UpdateInstances();
    }
}

// 应用悬停高亮效果（后处理）
// image: 要处理的图像
// 功能：通过修改匹配悬停实体的像素来应用高亮效果
// 注意：这是在CPU端进行的后处理，不影响累积
void Application::ApplyHoverHighlight(grassland::graphics::Image* image) {
    
    int width = window_->GetWidth();
    int height = window_->GetHeight();
    size_t pixel_count = width * height;
    
    // Download current image
    std::vector<float> image_data(pixel_count * 4);
    image->DownloadData(image_data.data());
    
    // Download entity ID buffer
    std::vector<int32_t> entity_ids(pixel_count);
    entity_id_image_->DownloadData(entity_ids.data());
    
    // Apply highlight to pixels matching hovered entity
    float highlight_factor = 0.4f; // Blend factor for white highlight
    for (size_t i = 0; i < pixel_count; i++) {
        if (entity_ids[i] == hovered_entity_id_) {
            // Lerp towards white (1, 1, 1) by highlight_factor
            image_data[i * 4 + 0] = image_data[i * 4 + 0] * (1.0f - highlight_factor) + 1.0f * highlight_factor;
            image_data[i * 4 + 1] = image_data[i * 4 + 1] * (1.0f - highlight_factor) + 1.0f * highlight_factor;
            image_data[i * 4 + 2] = image_data[i * 4 + 2] * (1.0f - highlight_factor) + 1.0f * highlight_factor;
            // Keep alpha unchanged
        }
    }
    
    // Upload modified image
    image->UploadData(image_data.data());
}

// 保存累积输出到PNG文件
// filename: 输出文件名
// 功能：将累积的输出图像保存为PNG文件（不包含悬停高亮）
void Application::SaveAccumulatedOutput(const std::string& filename) {
    int width = window_->GetWidth();
    int height = window_->GetHeight();
    int sample_count = film_->GetSampleCount();
    
    if (sample_count == 0) {
        grassland::LogWarning("Cannot save screenshot: no samples accumulated yet");
        return;
    }
    
    // Download accumulated color directly from film buffers (not the output image which may have highlights)
    std::vector<float> accumulated_colors(width * height * 4);
    film_->GetAccumulatedColorImage()->DownloadData(accumulated_colors.data());
    
    // Convert from accumulated sum to averaged color, then to 8-bit
    std::vector<uint8_t> byte_data(width * height * 4);
    for (size_t i = 0; i < width * height; i++) {
        // Average the accumulated color by dividing by sample count
        float r = accumulated_colors[i * 4 + 0] / static_cast<float>(sample_count);
        float g = accumulated_colors[i * 4 + 1] / static_cast<float>(sample_count);
        float b = accumulated_colors[i * 4 + 2] / static_cast<float>(sample_count);
        float a = accumulated_colors[i * 4 + 3] / static_cast<float>(sample_count);
        
        // Clamp to [0, 1] and convert to 8-bit
        byte_data[i * 4 + 0] = static_cast<uint8_t>(std::max(0.0f, std::min(1.0f, r)) * 255.0f);
        byte_data[i * 4 + 1] = static_cast<uint8_t>(std::max(0.0f, std::min(1.0f, g)) * 255.0f);
        byte_data[i * 4 + 2] = static_cast<uint8_t>(std::max(0.0f, std::min(1.0f, b)) * 255.0f);
        byte_data[i * 4 + 3] = static_cast<uint8_t>(std::max(0.0f, std::min(1.0f, a)) * 255.0f);
    }
    
    // Write PNG file
    int result = stbi_write_png(filename.c_str(), width, height, 4, byte_data.data(), width * 4);
    
    if (result) {
        // Get absolute path for logging
        std::filesystem::path abs_path = std::filesystem::absolute(filename);
        grassland::LogInfo("Screenshot saved: {} ({}x{}, {} samples)", 
                          abs_path.string(), width, height, sample_count);
    } else {
        grassland::LogError("Failed to save screenshot: {}", filename);
    }
}

// 渲染信息覆盖层（左侧UI面板）
// 功能：显示相机信息、景深控制、MSAA控制、运动模糊控制、环境光控制、场景信息、渲染信息等
// 注意：仅在相机禁用且UI未隐藏时显示
void Application::RenderInfoOverlay() {
    // Only show overlay when camera is disabled and UI is not hidden
    if (camera_enabled_ || ui_hidden_) {
        return;
    }

    // Create a window on the left side (matching entity panel style)
    ImGui::SetNextWindowPos(ImVec2(0.0f, 0.0f), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(350.0f, (float)window_->GetHeight()), ImGuiCond_Always);
    
    ImGuiWindowFlags window_flags = ImGuiWindowFlags_NoMove | 
                                     ImGuiWindowFlags_NoResize | 
                                     ImGuiWindowFlags_NoCollapse;
    
    if (!ImGui::Begin("Scene Information", nullptr, window_flags)) {
        ImGui::End();
        return;
    }

    // Camera Information
    ImGui::SeparatorText("Camera");
    ImGui::Text("Position: (%.2f, %.2f, %.2f)", camera_pos_.x, camera_pos_.y, camera_pos_.z);
    ImGui::Text("Direction: (%.2f, %.2f, %.2f)", camera_front_.x, camera_front_.y, camera_front_.z);
    ImGui::Text("Yaw: %.1f°  Pitch: %.1f°", yaw_, pitch_);
    ImGui::Text("Speed: %.3f", camera_speed_);
    ImGui::Text("Sensitivity: %.2f", mouse_sensitivity_);
    
    ImGui::Spacing();
    
    // Depth of Field controls
    ImGui::SeparatorText("Depth of Field");
    bool dof_changed = false;
    
    // Aperture slider
    if (ImGui::SliderFloat("Aperture", &aperture_, 0.0f, 1.0f, "%.3f")) {
        dof_changed = true;
    }
    ImGui::TextWrapped("Controls blur amount (0 = no blur)");
    
    ImGui::Spacing();
    
    // Focus distance is determined by the selected entity - read-only display
    ImGui::Text("Focus Distance: %.2f", focus_distance_);
    ImGui::TextWrapped("Focus locks to the selected entity; select a different entity to change focus.");
    
    // Auto-focus button (sets focus to center of screen or explicit scene targets)
    // NOTE: Removed manual focus preset buttons. Focus is now determined by entity selection only.
    
    // Reset DOF button
    if (ImGui::Button("Reset DOF", ImVec2(-1, 0))) {
        aperture_ = 0.12f;
        // keep focus locked if an entity is selected; otherwise reset to default
        if (focused_entity_id_ < 0) {
            focus_distance_ = 6.0f;
        }
        samples_per_frame_ = 2;
        dof_changed = true;
    }
    // Samples per frame slider
    if (ImGui::SliderInt("Samples per Frame", &samples_per_frame_, 1, 8)) {
        dof_changed = true;
    }
    
    // If DOF parameters changed, reset accumulation
    if (dof_changed && film_) {
        film_->Reset();
        accumulated_frames_ = 0;  // 重置累积帧计数
    }

    ImGui::Spacing();
    
    // ==================== MSAA 控制 ====================
    ImGui::SeparatorText("Anti-Aliasing (MSAA)");
    bool msaa_changed = false;
    
    // MSAA 模式下拉菜单
    const char* msaa_modes[] = { "Off", "2x MSAA", "4x MSAA", "8x MSAA", "Random" };
    if (ImGui::Combo("MSAA Mode", &msaa_mode_, msaa_modes, IM_ARRAYSIZE(msaa_modes))) {
        msaa_changed = true;
    }
    
    // 显示当前模式说明
    switch (msaa_mode_) {
        case MSAA_MODE_OFF:
            ImGui::TextWrapped("No anti-aliasing. Fastest but may show jagged edges.");
            break;
        case MSAA_MODE_2X:
            ImGui::TextWrapped("2 samples per pixel using standard D3D pattern.");
            break;
        case MSAA_MODE_4X:
            ImGui::TextWrapped("4 samples per pixel (rotated grid). Good balance.");
            break;
        case MSAA_MODE_8X:
            ImGui::TextWrapped("8 samples per pixel. Best quality, slower.");
            break;
        case MSAA_MODE_RANDOM:
            ImGui::TextWrapped("Random jitter sampling. Best for path tracing convergence.");
            break;
    }
    
    // 显示累积帧数
    ImGui::Text("Accumulated Frames: %d", accumulated_frames_);
    
    // MSAA 参数改变时重置累积
    if (msaa_changed && film_) {
        film_->Reset();
        accumulated_frames_ = 0;
    };
    
    // ==================== Motion Blur 控制 ====================
    ImGui::SeparatorText("Motion Blur");
    bool motion_blur_changed = false;
    
    // Motion Blur 模式下拉菜单
    const char* motion_blur_modes[] = { "Off", "Camera", "Object", "Radial", "Directional" };
    if (ImGui::Combo("Motion Blur Mode", &motion_blur_mode_, motion_blur_modes, IM_ARRAYSIZE(motion_blur_modes))) {
        motion_blur_changed = true;
    }
    
    // 显示当前模式说明
    switch (motion_blur_mode_) {
        case 0: // Off
            ImGui::TextWrapped("No motion blur. Standard rendering.");
            break;
        case 1: // Camera
            ImGui::TextWrapped("Camera motion blur. Simulates shutter time during camera movement.");
            break;
        case 2: // Object
            ImGui::TextWrapped("Object motion blur. Blurs objects with velocity (green/red/gold exhibits).");
            break;
        case 3: // Radial
            ImGui::TextWrapped("Radial blur from screen center. Creates zoom effect.");
            break;
        case 4: // Directional
            ImGui::TextWrapped("Directional blur along specified direction.");
            break;
    }
    
    // 强度滑块（只在开启运动模糊时显示）
    if (motion_blur_mode_ > 0) {
        if (ImGui::SliderFloat("Blur Intensity", &motion_blur_intensity_, 0.0f, 0.3f, "%.2f")) {
            motion_blur_changed = true;
        }
        
        // 方向控制（只在方向性模糊时显示）
        if (motion_blur_mode_ == 4) {
            float dir[2] = { motion_blur_direction_.x, motion_blur_direction_.y };
            if (ImGui::SliderFloat2("Blur Direction", dir, -1.0f, 1.0f)) {
                motion_blur_direction_ = glm::vec2(dir[0], dir[1]);
                motion_blur_changed = true;
            }
            // 归一化方向
            float len = glm::length(motion_blur_direction_);
            if (len > 0.001f) {
                motion_blur_direction_ /= len;
            }
        }
    }
    
    // Motion Blur 参数改变时重置累积
    if (motion_blur_changed && film_) {
        film_->Reset();
        accumulated_frames_ = 0;
    }
    
    // ==================== Skybox / Environment Lighting 控制 ====================
    ImGui::SeparatorText("Environment Lighting");
    bool skybox_changed = false;
    
    // 显示当前状态
    if (skybox_info_.has_environment_map > 0.5f) {
        ImGui::TextColored(ImVec4(0.5f, 1.0f, 0.5f, 1.0f), "Mode: HDR Environment Map");
    } else {
        ImGui::TextColored(ImVec4(1.0f, 1.0f, 0.5f, 1.0f), "Mode: Procedural Sky");
    }
    
    // 环境光强度
    if (ImGui::SliderFloat("Env Intensity", &skybox_info_.environment_intensity, 0.0f, 5.0f, "%.2f")) {
        skybox_changed = true;
    }
    
    // HDR 环境贴图旋转 (仅在使用 HDR 时显示)
    if (skybox_info_.has_environment_map > 0.5f) {
        float rotation_deg = skybox_info_.environment_rotation * 180.0f / 3.14159265f;
        if (ImGui::SliderFloat("Env Rotation", &rotation_deg, 0.0f, 360.0f, "%.1f deg")) {
            skybox_info_.environment_rotation = rotation_deg * 3.14159265f / 180.0f;
            skybox_changed = true;
        }
    }
    
    // 程序化天空颜色 (始终可调，影响后备天空)
    if (ImGui::TreeNode("Sky Colors")) {
        if (ImGui::ColorEdit3("Zenith", &skybox_info_.zenith_color.x)) {
            skybox_changed = true;
        }
        if (ImGui::ColorEdit3("Horizon", &skybox_info_.horizon_color.x)) {
            skybox_changed = true;
        }
        if (ImGui::ColorEdit3("Ground", &skybox_info_.ground_color.x)) {
            skybox_changed = true;
        }
        ImGui::TreePop();
    }
    
    // Skybox 参数改变时重置累积
    if (skybox_changed) {
        skybox_need_upload_ = true;
        if (film_) {
            film_->Reset();
            accumulated_frames_ = 0;
        }
    }

    // Scene Information
    ImGui::SeparatorText("Scene");
    size_t entity_count = scene_->GetEntityCount();
    ImGui::Text("Entities: %zu", entity_count);
    ImGui::Text("Materials: %zu", entity_count); // One material per entity
    
    // Show hovered entity
    if (hovered_entity_id_ >= 0) {
        ImGui::TextColored(ImVec4(1.0f, 1.0f, 0.0f, 1.0f), "Hovered: Entity #%d", hovered_entity_id_);
    } else {
        ImGui::Text("Hovered: None");
    }
    
    // Show selected entity
    if (selected_entity_id_ >= 0) {
        ImGui::TextColored(ImVec4(0.5f, 1.0f, 0.5f, 1.0f), "Selected: Entity #%d", selected_entity_id_);
    } else {
        ImGui::Text("Selected: None");
    }
    
    // Show focused entity (if focus is locked to an entity)
    if (focused_entity_id_ >= 0) {
        ImGui::TextColored(ImVec4(0.9f, 0.7f, 0.35f, 1.0f), "Focused: Entity #%d", focused_entity_id_);
    } else {
        ImGui::Text("Focused: None");
    }
    
    ImGui::Spacing();
    
    // Show hovered pixel information
    ImGui::SeparatorText("Pixel Inspector");
    ImGui::Text("Mouse Position: (%d, %d)", (int)mouse_x_, (int)mouse_y_);
    
    // Display color value with a color preview box
    ImGui::Text("Pixel Color:");
    ImGui::SameLine();
    ImGui::ColorButton("##pixel_color_preview", 
                       ImVec4(hovered_pixel_color_.r, hovered_pixel_color_.g, hovered_pixel_color_.b, 1.0f),
                       ImGuiColorEditFlags_NoTooltip | ImGuiColorEditFlags_NoBorder,
                       ImVec2(40, 20));
    
    ImGui::Text("  R: %.3f", hovered_pixel_color_.r);
    ImGui::Text("  G: %.3f", hovered_pixel_color_.g);
    ImGui::Text("  B: %.3f", hovered_pixel_color_.b);
    
    // Show as 8-bit values too (common for texture work)
    ImGui::Text("  RGB (8-bit): (%d, %d, %d)", 
                (int)(hovered_pixel_color_.r * 255.0f),
                (int)(hovered_pixel_color_.g * 255.0f),
                (int)(hovered_pixel_color_.b * 255.0f));

    // Hover stability slider
    ImGui::Spacing();
    ImGui::SliderInt("Hover Stability (frames)", &hover_consistency_threshold_, 1, 8);
    
    // Calculate total triangles
    size_t total_triangles = 0;
    for (const auto& entity : scene_->GetEntities()) {
        if (entity && entity->GetIndexBuffer()) {
            // Each 3 indices = 1 triangle
            size_t indices = entity->GetIndexBuffer()->Size() / sizeof(uint32_t);
            total_triangles += indices / 3;
        }
    }
    ImGui::Text("Total Triangles: %zu", total_triangles);

    ImGui::Spacing();

    // Render Information
    ImGui::SeparatorText("Render");
    ImGui::Text("Resolution: %d x %d", window_->GetWidth(), window_->GetHeight());
    ImGui::Text("Backend: %s", 
                core_->API() == grassland::graphics::BACKEND_API_VULKAN ? "Vulkan" : "D3D12");
    ImGui::Text("Device: %s", core_->DeviceName().c_str());
    
    ImGui::Spacing();
    
    // Accumulation Information
    ImGui::SeparatorText("Accumulation");
    if (!camera_enabled_) {
        ImGui::TextColored(ImVec4(0.5f, 1.0f, 0.5f, 1.0f), "Status: Active");
        ImGui::Text("Samples: %d", film_->GetSampleCount());
    } else {
        ImGui::TextColored(ImVec4(0.7f, 0.7f, 0.7f, 1.0f), "Status: Paused");
        ImGui::Text("(Disable camera to accumulate)");
    }

    ImGui::Spacing();

    // Light controls (quick debug + adjust exposure)
    ImGui::SeparatorText("Lights / Exposure");
    bool lights_changed = false;
    if (ImGui::SliderFloat("Exposure", &exposure_, 0.01f, 1.0f, "%.2f")) {
        lights_changed = true;
    }

    // Area light 0 controls - primary ceiling light
    if (!area_lights_.empty()) {
        AreaLight &al0 = area_lights_[0];
        ImGui::Text("Area Light 0 (Ceiling)");
        if (ImGui::SliderFloat("Area Light 0 Strength", &al0.strength, 0.0f, 200.0f, "%.1f")) {
            lights_changed = true;
        }
        if (ImGui::ColorEdit3("Area Light 0 Color", &al0.color.x)) {
            lights_changed = true;
        }
    }

    // Point light 0 controls
    if (!point_lights_.empty()) {
        PointLight &pl0 = point_lights_[0];
        ImGui::Text("Point Light 0");
        if (ImGui::SliderFloat("Point Light 0 Strength", &pl0.strength, 0.0f, 2000.0f, "%.1f")) {
            lights_changed = true;
        }
        if (ImGui::ColorEdit3("Point Light 0 Color", &pl0.color.x)) {
            lights_changed = true;
        }
        if (ImGui::DragFloat3("Point Light 0 Position", &pl0.position.x, 0.1f, -10.0f, 10.0f)) {
            lights_changed = true;
        }
        if (ImGui::Button("Reset Point Light 0 to Room", ImVec2(-1, 0))) {
            pl0.position = glm::vec3(2.0f, 3.8f, 5.0f);
            pl0.strength = 2000.0f;
            exposure_ = 1.0f;
            lights_changed = true;
        }
    }

    // Upload light parameters if changed
    if (lights_changed) {
        lights_need_upload_ = true;
        if (film_) film_->Reset(); // reset accumulation on lighting changes
    }

    // Controls hint
    ImGui::SeparatorText("Controls");
    ImGui::TextColored(ImVec4(0.5f, 1.0f, 0.5f, 1.0f), "Right Click to enable camera");
    ImGui::Text("W/A/S/D - Move camera");
    ImGui::Text("Space/Shift - Up/Down");
    ImGui::Text("Mouse - Look around");
    ImGui::Spacing();
    ImGui::TextColored(ImVec4(1.0f, 1.0f, 0.5f, 1.0f), "Hold Tab to hide UI");
    ImGui::TextColored(ImVec4(0.5f, 1.0f, 1.0f, 1.0f), "Ctrl+S to save screenshot");

    ImGui::End();
}

// 渲染实体检查器面板（右侧UI面板）
// 功能：显示实体选择下拉菜单、选中实体的详细信息（变换、材质、网格等）、材质编辑控件
// 注意：仅在相机禁用且UI未隐藏时显示
void Application::RenderEntityPanel() {
    // Only show entity panel when camera is disabled and UI is not hidden
    if (camera_enabled_ || ui_hidden_) {
        return;
    }

    // Create a window on the right side
    ImGui::SetNextWindowPos(ImVec2((float)window_->GetWidth() - 350.0f, 0.0f), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(350.0f, (float)window_->GetHeight()), ImGuiCond_Always);
    
    ImGuiWindowFlags window_flags = ImGuiWindowFlags_NoMove | 
                                     ImGuiWindowFlags_NoResize | 
                                     ImGuiWindowFlags_NoCollapse;
    
    if (!ImGui::Begin("Entity Inspector", nullptr, window_flags)) {
        ImGui::End();
        return;
    }

    ImGui::SeparatorText("Entity Selection");
    
    const auto& entities = scene_->GetEntities();
    size_t entity_count = entities.size();
    
    // Entity dropdown with limited height
    ImGui::Text("Select Entity:");
    
    // Create preview text
    std::string preview_text = selected_entity_id_ >= 0 ? 
        "Entity #" + std::to_string(selected_entity_id_) : 
        "None";
    
    ImGui::SetNextItemWidth(-1); // Full width
    if (ImGui::BeginCombo("##entity_select", preview_text.c_str())) {
        // Add "None" option
        bool is_selected = (selected_entity_id_ == -1);
        if (ImGui::Selectable("None", is_selected)) {
            selected_entity_id_ = -1;
        }
        if (is_selected) {
            ImGui::SetItemDefaultFocus();
        }
        
        // Add all entities to the list
        for (size_t i = 0; i < entity_count; i++) {
            std::string label = "Entity #" + std::to_string(i);
            bool is_entity_selected = (selected_entity_id_ == (int)i);
            
            if (ImGui::Selectable(label.c_str(), is_entity_selected)) {
                selected_entity_id_ = (int)i;
                // Lock focus to this entity
                focused_entity_id_ = selected_entity_id_;
                if (film_) film_->Reset();
            }
            
            if (is_entity_selected) {
                ImGui::SetItemDefaultFocus();
            }
        }
        
        ImGui::EndCombo();
    }
    
    ImGui::Spacing();
    
    // Show details if an entity is selected
    if (selected_entity_id_ >= 0 && selected_entity_id_ < (int)entity_count) {
        ImGui::SeparatorText("Entity Details");
        
        const auto& entity = entities[selected_entity_id_];
        
        // Transform information
        ImGui::Text("Transform:");
        glm::mat4 transform = entity->GetTransform();
        glm::vec3 position = glm::vec3(transform[3]);
        ImGui::Text("  Position: (%.2f, %.2f, %.2f)", position.x, position.y, position.z);
        
        // Scale
        glm::vec3 scale = glm::vec3(
            glm::length(glm::vec3(transform[0])),
            glm::length(glm::vec3(transform[1])),
            glm::length(glm::vec3(transform[2]))
        );
        ImGui::Text("  Scale: (%.2f, %.2f, %.2f)", scale.x, scale.y, scale.z);
        
        ImGui::Spacing();
        
        // Material information
        ImGui::SeparatorText("Material");
        Material mat = entity->GetMaterial();
        bool material_changed = false;

        ImGui::Text("Base Color:");
        if (ImGui::ColorEdit3("##base_color", &mat.base_color[0])) {
            material_changed = true;
        }
        ImGui::Text("  RGB: (%.2f, %.2f, %.2f)", mat.base_color.r, mat.base_color.g, mat.base_color.b);

        if (ImGui::SliderFloat("Roughness", &mat.roughness, 0.0f, 1.0f)) material_changed = true;
        if (ImGui::SliderFloat("Metallic", &mat.metallic, 0.0f, 1.0f)) material_changed = true;
        if (ImGui::SliderFloat("Specular", &mat.specular, 0.0f, 1.0f)) material_changed = true;
        if (ImGui::SliderFloat("Specular Tint", &mat.specular_tint, 0.0f, 1.0f)) material_changed = true;
        if (ImGui::SliderFloat("Anisotropic", &mat.anisotropic, 0.0f, 1.0f)) material_changed = true;
        if (ImGui::SliderFloat("Anisotropic Rotation", &mat.anisotropic_rotation, 0.0f, 1.0f)) material_changed = true;
        if (ImGui::SliderFloat("Sheen", &mat.sheen, 0.0f, 1.0f)) material_changed = true;
        if (ImGui::SliderFloat("Sheen Tint", &mat.sheen_tint, 0.0f, 1.0f)) material_changed = true;
        if (ImGui::SliderFloat("Clearcoat", &mat.clearcoat, 0.0f, 1.0f)) material_changed = true;
        if (ImGui::SliderFloat("Clearcoat Roughness", &mat.clearcoat_roughness, 0.0f, 1.0f)) material_changed = true;
        if (ImGui::SliderFloat("Transmission", &mat.transmission, 0.0f, 1.0f)) material_changed = true;
        if (ImGui::SliderFloat("Transmission Roughness", &mat.transmission_roughness, 0.0f, 1.0f)) material_changed = true;
        if (ImGui::SliderFloat("IOR", &mat.ior, 1.0f, 3.0f)) material_changed = true;
        ImGui::Text("Transmission Color:");
        if (ImGui::ColorEdit3("##transmission_color", &mat.transmission_color[0])) material_changed = true;
        if (ImGui::SliderFloat("Subsurface", &mat.subsurface, 0.0f, 1.0f)) material_changed = true;
        ImGui::Text("Subsurface Color:");
        if (ImGui::ColorEdit3("##subsurface_color", &mat.subsurface_color[0])) material_changed = true;
        if (ImGui::SliderFloat3("Subsurface Radius", &mat.subsurface_radius[0], 0.0f, 10.0f)) material_changed = true;
        ImGui::Text("Emission Color:");
        if (ImGui::ColorEdit3("##emission_color", &mat.emission_color[0])) material_changed = true;
        if (ImGui::SliderFloat("Emission Strength", &mat.emission_strength, 0.0f, 1e6f)) material_changed = true;
        if (ImGui::SliderFloat("Alpha Threshold", &mat.alpha_threshold, 0.0f, 1.0f)) material_changed = true;
        {
            bool has_alpha = (mat.has_alpha_map > 0.5f);
            if (ImGui::Checkbox("Has Alpha Map", &has_alpha)) {
                mat.has_alpha_map = has_alpha ? 1.0f : 0.0f;
                material_changed = true;
            }
        }
        
        ImGui::Spacing();
        
        // Mesh information
        ImGui::SeparatorText("Mesh");
        if (entity->GetIndexBuffer()) {
            size_t index_count = entity->GetIndexBuffer()->Size() / sizeof(uint32_t);
            size_t triangle_count = index_count / 3;
            ImGui::Text("Triangles: %zu", triangle_count);
            ImGui::Text("Indices: %zu", index_count);
        }
        
        if (entity->GetVertexBuffer()) {
            size_t vertex_size = sizeof(float) * 3; // Assuming pos(3)
            size_t vertex_count = entity->GetVertexBuffer()->Size() / vertex_size;
            ImGui::Text("Vertices: %zu", vertex_count);
        }
        
        ImGui::Spacing();
        
        // BLAS information
        ImGui::SeparatorText("Acceleration Structure");
        if (entity->GetBLAS()) {
            ImGui::Text("BLAS: Built");
        } else {
            ImGui::Text("BLAS: Not built");
        }
        
        ImGui::Spacing();
        // 按钮：将 DOF 聚焦到当前选中实体
        // Focus DOF is automatically locked to the selected entity. Select an entity to change focus.

        // 可选：让相机朝向该实体（并保留当前位置），用于更直观的查看
        if (ImGui::Button("Auto-Focus (Raycast)", ImVec2(-1.0f, 0.0f))) {
            // Auto-focus selected entity by scanning the ID buffer and reading depth
            if (selected_entity_id_ >= 0) {
                int width = window_->GetWidth();
                int height = window_->GetHeight();
                std::vector<int32_t> ids(width * height);
                std::vector<float> depths(width * height);
                entity_id_image_->DownloadData(ids.data());
                depth_image_->DownloadData(depths.data());
                int foundIndex = -1;
                for (int i = 0; i < width * height; ++i) {
                    if (ids[i] == selected_entity_id_) { foundIndex = i; break; }
                }
                if (foundIndex >= 0) {
                    float d = depths[foundIndex];
                    if (d > 0.0f) {
                        focus_distance_ = d;
                        focused_entity_id_ = selected_entity_id_;
                        if (film_) film_->Reset();
                        grassland::LogInfo("Auto-focused to entity #{} at depth {}", selected_entity_id_, d);
                    } else {
                        grassland::LogWarning("Auto-focus found entity but depth is 0");
                    }
                } else {
                    grassland::LogWarning("Auto-focus failed: selected entity not visible in ID buffer");
                }
            }
        }
        if (ImGui::Button("Camera Look At Entity", ImVec2(-1.0f, 0.0f))) {
            glm::mat4 transform = entity->GetTransform();
            glm::vec3 entity_pos = glm::vec3(transform[3]);
            camera_front_ = glm::normalize(entity_pos - camera_pos_);
            // 重置累积
            if (film_) film_->Reset();
            grassland::LogInfo("Camera now looks at Entity #{}", selected_entity_id_);
        }

        // 如果材质发生变化，应用并更新 GPU 缓冲
        if (material_changed) {
            // Apply to entity and update global materials buffer
            Material old_mat = entity->GetMaterial();
            entity->SetMaterial(mat);
            // Update scene materials buffer (thin wrapper)
            scene_->UpdateMaterials();
            if (film_) film_->Reset();
            grassland::LogInfo("Updated material of entity {}", selected_entity_id_);
        }
    } else {
        ImGui::TextDisabled("No entity selected");
        ImGui::Spacing();
        ImGui::TextWrapped("Hover over an entity to highlight it, then left-click to select. Or use the dropdown above.");
    }
    
    ImGui::End();
}

// 渲染一帧
// 功能：清空缓冲区、绑定资源、调度光线追踪、应用后处理、渲染UI、呈现图像
void Application::OnRender() {
    // 如果窗口正在关闭，不渲染
    if (!alive_) {
        return;
    }


    std::unique_ptr<grassland::graphics::CommandContext> command_context;
    core_->CreateCommandContext(&command_context);
    command_context->CmdClearImage(color_image_.get(), { {0.6, 0.7, 0.8, 1.0} });
    
    // Clear entity ID buffer with -1 (no entity)
    command_context->CmdClearImage(entity_id_image_.get(), { {-1, 0, 0, 0} });
    // Clear depth image
    command_context->CmdClearImage(depth_image_.get(), { {0.0f, 0.0f, 0.0f, 0.0f} });
    
    command_context->CmdBindRayTracingProgram(program_.get());
    command_context->CmdBindResources(0, scene_->GetTLAS(), grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(1, { color_image_.get() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(2, { camera_object_buffer_.get() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(3, { scene_->GetMaterialsBuffer() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(4, { hover_info_buffer_.get() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(5, { entity_id_image_.get() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(6, { film_->GetAccumulatedColorImage() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(7, { film_->GetAccumulatedSamplesImage() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(12, { depth_image_.get() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(8, { point_lights_buffer_.get() }, grassland::graphics::BIND_POINT_RAYTRACING);  // 绑定点光源
    command_context->CmdBindResources(9, { area_lights_buffer_.get() }, grassland::graphics::BIND_POINT_RAYTRACING);  // 绑定面光源
    
    // 绑定 reserved 空间（space13, space14）- 使用现有缓冲区作为占位符
    // D3D12 要求所有声明的资源槽都必须被绑定
    command_context->CmdBindResources(13, { scene_->GetMaterialsBuffer() }, grassland::graphics::BIND_POINT_RAYTRACING);  // space13 placeholder
    command_context->CmdBindResources(14, { camera_object_buffer_.get() }, grassland::graphics::BIND_POINT_RAYTRACING);   // space14 placeholder
    
    // 绑定实体速度缓冲区（用于物体运动模糊）- 必须总是绑定
    command_context->CmdBindResources(15, { scene_->GetVelocitiesBuffer() }, grassland::graphics::BIND_POINT_RAYTRACING);
    
    // 绑定 Skybox / Environment Map 资源
    command_context->CmdBindResources(16, { skybox_info_buffer_.get() }, grassland::graphics::BIND_POINT_RAYTRACING);
    // 环境贴图必须始终有效 (初始化时已创建默认贴图)
    command_context->CmdBindResources(17, { environment_map_.get() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(18, { environment_sampler_.get() }, grassland::graphics::BIND_POINT_RAYTRACING);
    
    // 绑定全局几何缓冲区（用于从OBJ文件加载的几何数据）
    command_context->CmdBindResources(19, { scene_->GetGlobalVertexBuffer() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(20, { scene_->GetGlobalNormalBuffer() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(21, { scene_->GetGlobalTexcoordBuffer() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(22, { scene_->GetGlobalIndexBuffer() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdBindResources(23, { scene_->GetEntityOffsetsBuffer() }, grassland::graphics::BIND_POINT_RAYTRACING);

    // If UI changed lights, re-upload data to GPU buffer (so shader sees changes)
    if (lights_need_upload_) {
        if (point_lights_buffer_) point_lights_buffer_->UploadData(point_lights_.data(), sizeof(PointLight) * point_lights_.size());
        if (area_lights_buffer_) area_lights_buffer_->UploadData(area_lights_.data(), sizeof(AreaLight) * area_lights_.size());
        lights_need_upload_ = false;
        grassland::LogInfo("Light buffers updated (uploaded to GPU). PL0 pos=(%.2f, %.2f, %.2f) strength=%.1f", point_lights_[0].position.x, point_lights_[0].position.y, point_lights_[0].position.z, point_lights_[0].strength);
    }
    
    // If skybox parameters changed, re-upload
    if (skybox_need_upload_) {
        if (skybox_info_buffer_) {
            skybox_info_buffer_->UploadData(&skybox_info_, sizeof(SkyboxInfo));
        }
        skybox_need_upload_ = false;
        grassland::LogInfo("Skybox info updated (uploaded to GPU)");
    }
    
    // Bind textures and sampler (space10)
    if (scene_->GetTextureCount() > 0) {
        command_context->CmdBindResources(10, scene_->GetTextures(), grassland::graphics::BIND_POINT_RAYTRACING);
        command_context->CmdBindResources(11, { texture_sampler_.get() }, grassland::graphics::BIND_POINT_RAYTRACING);
    }
    
    // 暂时注释掉全局几何缓冲区绑定
    // command_context->CmdBindResources(9, { scene_->GetGlobalVertexBuffer() }, grassland::graphics::BIND_POINT_RAYTRACING);
    // command_context->CmdBindResources(10, { scene_->GetGlobalNormalBuffer() }, grassland::graphics::BIND_POINT_RAYTRACING);
    // command_context->CmdBindResources(11, { scene_->GetGlobalIndexBuffer() }, grassland::graphics::BIND_POINT_RAYTRACING);
    // command_context->CmdBindResources(12, { scene_->GetEntityOffsetsBuffer() }, grassland::graphics::BIND_POINT_RAYTRACING);
    command_context->CmdDispatchRays(window_->GetWidth(), window_->GetHeight(), 1);
    
    // When camera is disabled, increment sample count
    // Note: shader already computes accumulated average and tone maps to color_image_
    // so we can use color_image_ directly instead of calling DevelopToOutput
    grassland::graphics::Image* display_image = color_image_.get();
    if (!camera_enabled_) {
        film_->IncrementSampleCount();
        accumulated_frames_++;  // 递增累积帧计数（用于时间累积 MSAA）
        // Use shader's output directly (already tone mapped and gamma corrected)
        display_image = color_image_.get();
    }
    
    // Apply hover highlighting as post-process (doesn't affect accumulation)
    if (hovered_entity_id_ >= 0 && !camera_enabled_) {
        ApplyHoverHighlight(display_image);
    }
    
    // Render ImGui overlay
    window_->BeginImGuiFrame();
    RenderInfoOverlay();
    RenderEntityPanel();
    window_->EndImGuiFrame();
    
    command_context->CmdPresent(window_.get(), display_image);
    core_->SubmitCommandContext(command_context.get());
}
