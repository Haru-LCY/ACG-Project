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

Application::Application(grassland::graphics::BackendAPI api) {
    grassland::graphics::CreateCore(api, grassland::graphics::Core::Settings{}, &core_);
    core_->InitializeLogicalDeviceAutoSelect(true);

    grassland::LogInfo("Device Name: {}", core_->DeviceName());
    grassland::LogInfo("- Ray Tracing Support: {}", core_->DeviceRayTracingSupport());
}

Application::~Application() {
    core_.reset();
}

// Event handler for keyboard input
// Poll keyboard state directly to ensure it works even when ImGui is active
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

// Event handler for mouse movement
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

// Event handler for mouse button clicks
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

    // Create scene
    scene_ = std::make_unique<Scene>(core_.get());

    // Add entities to the scene
    // Ground plane
    {
        auto ground = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.8f, 0.8f, 0.8f), 0.8f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, -1.0f, 0.0f)), 
                      glm::vec3(10.0f, 0.1f, 10.0f))
        );
        scene_->AddEntity(ground);
    }

    // Left wall
    {
        auto left_wall = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.9f, 0.9f, 0.9f), 0.9f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(-5.0f, 2.0f, 0.0f)), 
                      glm::vec3(0.1f, 4.0f, 10.0f))
        );
        scene_->AddEntity(left_wall);
    }

    // Right wall
    {
        auto right_wall = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.9f, 0.9f, 0.9f), 0.9f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(5.0f, 2.0f, 0.0f)), 
                      glm::vec3(0.1f, 4.0f, 10.0f))
        );
        scene_->AddEntity(right_wall);
    }

    // Back wall
    {
        auto back_wall = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.9f, 0.9f, 0.9f), 0.9f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 2.0f, -5.0f)), 
                      glm::vec3(10.0f, 4.0f, 0.1f)),
            "textures/sakura.png"
        );
        scene_->AddEntity(back_wall);
    }

    // Ceiling
    {
        auto ceiling = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.9f, 0.9f, 0.9f), 0.9f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 5.0f, 0.0f)), 
                      glm::vec3(10.0f, 0.1f, 10.0f))
        );
        scene_->AddEntity(ceiling);
    }

    // Green metallic sphere (中景 - 作为焦平面目标)
     {
         auto green_sphere = std::make_shared<Entity>(
             "meshes/octahedron.obj",
             Material(glm::vec3(0.2f, 1.0f, 0.2f), 0.2f, 0.8f),
             // 放在 z=2 作为中景焦点
             glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 0.5f, 2.0f))
         );
         scene_->AddEntity(green_sphere);
     }
     
    // Textured copper sphere (幕后/中景)
    {
        auto copper_sphere = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.3f, 0.9f),  // 白色基础,金属
            // 将铜球移到中景靠后位置，增加前后景深变化
            glm::translate(glm::mat4(1.0f), glm::vec3(-2.5f, 0.5f, 0.0f)),
            "textures/copper/Sphere_Base_color.png"
        );
        scene_->AddEntity(copper_sphere);
    }

    // Transparent blue glass cube (背景)
    {
        auto blue_cube = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.3f, 0.3f, 1.0f), 0.05f, 0.0f, 0.95f, 1.5f), // 蓝色玻璃：明显的蓝色色调
            // Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.3f, 0.9f),  // 白色基础,金属
            // 将蓝色玻璃放在稍微靠后的背景位置
            glm::translate(glm::mat4(1.0f), glm::vec3(2.0f, 0.5f, -2.0f)),
            "textures/sakura.png"
        );
        scene_->AddEntity(blue_cube);
    }

    // {
    //     auto blue_cube = std::make_shared<Entity>(
    //         "meshes/cube.obj",
    //         // Material(glm::vec3(0.3f, 0.3f, 1.0f), 0.05f, 0.0f, 0.95f, 1.5f), // 蓝色玻璃：明显的蓝色色调
    //         Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.3f, 0.9f),  // 白色基础,金属
    //         // 将蓝色玻璃放在稍微靠后的背景位置
    //         glm::translate(glm::mat4(1.0f), glm::vec3(2.0f, 0.5f, -2.0f)),
    //         "textures/sakura.png"
    //     );
    //     scene_->AddEntity(blue_cube);
    // }

    // Foreground specular sphere (近景 - 应该被模糊)
    {
        auto fg_sphere = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(1.0f, 0.9f, 0.6f), 0.05f, 1.0f), // 高金属低粗糙突出高光
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 0.35f, 4.0f)), glm::vec3(0.5f))
        );
        scene_->AddEntity(fg_sphere);
    }

    // Background ornamental sphere (远景 - 强烈模糊形成bokeh高光)
    {
        auto bg_sphere = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(1.0f, 1.0f, 0.85f), 0.05f, 1.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 0.4f, -7.0f)), glm::vec3(0.6f))
        );
        scene_->AddEntity(bg_sphere);
    }
    

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
    
    // 添加一个主光源（强白光）- 正上方偏右后方（更自然的布光）
    point_lights_[0].position = glm::vec3(2.0f, 8.0f, 5.0f);
    point_lights_[0].color = glm::vec3(1.0f, 1.0f, 1.0f);
    point_lights_[0].strength = 0.0f; // 增强主光源强度
    point_lights_[0].radius = 0.1f;
    
    // 添加一个补光光源（柔和白光）- 左上方，避免产生强反光
    point_lights_[1].position = glm::vec3(-5.0f, 5.0f, 3.0f);
    point_lights_[1].color = glm::vec3(1.0f, 1.0f, 1.0f);
    point_lights_[1].strength = 0.0f;
    point_lights_[1].radius = 0.1f;
    
    // 添加一个环境光（模拟天空反射）
    point_lights_[2].position = glm::vec3(0.0f, 0.5f, 6.0f);
    point_lights_[2].color = glm::vec3(0.95f, 0.95f, 1.0f);
    point_lights_[2].strength = 0.0f; // 增加一点环境照明
    point_lights_[2].radius = 0.1f;

    // 添加一个背景高亮点光源用于产生远处的bokeh高光
    point_lights_[3].position = glm::vec3(0.0f, 1.2f, -7.0f);
    point_lights_[3].color = glm::vec3(1.0f, 0.9f, 0.7f);
    point_lights_[3].strength = 20.0f; // 很亮，用于产生明显的bokeh
    point_lights_[3].radius = 0.05f;    // 小半径产生更集中的高光
    
    // 其余光源强度设为0（未使用）
    for (int i = 3; i < 16; ++i) {
        point_lights_[i].position = glm::vec3(0.0f);
        point_lights_[i].color = glm::vec3(1.0f);
        point_lights_[i].strength = 0.0f;  // 强度为0表示未激活
        point_lights_[i].radius = 0.0f;
    }
    
    // 创建并上传点光源缓冲区
    core_->CreateBuffer(sizeof(PointLight) * 16, grassland::graphics::BUFFER_TYPE_DYNAMIC, &point_lights_buffer_);
    point_lights_buffer_->UploadData(point_lights_.data(), sizeof(PointLight) * 16);
    grassland::LogInfo("初始化了 {} 个点光源", 3);

    // 初始化面光源数组（最多8个）
    area_lights_.resize(8);
    // 配置主光源 - 天花板白光
    area_lights_[0].position = glm::vec3(0.0f, 4.0f, 0.0f);      // 上方4米
    area_lights_[0].color = glm::vec3(1.0f, 1.0f, 1.0f);         // 白色
    area_lights_[0].strength = 6.0f;                             // 增加强度以更好照亮室内并产生高光
    area_lights_[0].width = 2.0f;                                 // 减小尺寸
    area_lights_[0].height = 2.0f;                                // 减小尺寸
    area_lights_[0].direction = glm::normalize(glm::vec3(0.0f, -1.0f, 0.0f));  // 向下
    area_lights_[0].u_axis = glm::normalize(glm::vec3(1.0f, 0.0f, 0.0f));      // X轴
    area_lights_[0].v_axis = glm::normalize(glm::vec3(0.0f, 0.0f, 1.0f));      // Z轴
    area_lights_[0].pad1 = 0.0f;
    area_lights_[0].pad2 = 0.0f;
    
    // 配置左侧光
    area_lights_[1].position = glm::vec3(-5.0f, 2.0f, 0.0f);     // 左侧
    area_lights_[1].color = glm::vec3(0.3f, 0.3f, 1.0f);         // 蓝色
    area_lights_[1].strength = 0.0f;                             // 降低强度
    area_lights_[1].width = 1.0f;                                 // 1米宽
    area_lights_[1].height = 2.0f;                                // 2米高
    area_lights_[1].direction = glm::normalize(glm::vec3(1.0f, 0.0f, 0.0f));   // 向右
    area_lights_[1].u_axis = glm::normalize(glm::vec3(0.0f, 1.0f, 0.0f));      // Y轴
    area_lights_[1].v_axis = glm::normalize(glm::vec3(0.0f, 0.0f, 1.0f));      // Z轴
    area_lights_[1].pad1 = 0.0f;
    area_lights_[1].pad2 = 0.0f;
    
    // 配置右侧光
    area_lights_[2].position = glm::vec3(5.0f, 2.0f, 0.0f);      // 右侧
    area_lights_[2].color = glm::vec3(0.3f, 1.0f, 0.3f);         // 绿色
    area_lights_[2].strength = 0.0f;                             // 降低强度
    area_lights_[2].width = 1.0f;                                 // 1米宽
    area_lights_[2].height = 2.0f;                                // 2米高
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
    grassland::LogInfo("初始化了 {} 个面光源", 3);

    // Initialize camera state member variables
    camera_pos_ = glm::vec3{ 0.0f, 1.0f, 8.0f }; // 远离一些以扩展景深距离
    camera_up_ = glm::vec3{ 0.0f, 1.0f, 0.0f }; // World up
    camera_speed_ = 0.01f;

    // Initialize new mouse/view variables
    yaw_ = -90.0f; // Point down -Z
    pitch_ = 0.0f;
    last_x_ = (float)window_->GetWidth() / 2.0f;
    last_y_ = (float)window_->GetHeight() / 2.0f;
    mouse_sensitivity_ = 0.1f;
    first_mouse_ = true;
    // Initialize hover stability variables
    hover_candidate_id_ = -2; // invalid
    hover_consistency_count_ = 0;
    hover_consistency_threshold_ = 2; // default 2 frames consistency
    
    // Initialize depth of field parameters
    aperture_ = 0.12f;        // 默认开启景深，这个值比较明显（可在UI调整）
    focus_distance_ = 6.0f;  // 默认焦距6米 -> focal plane at z=2 (camera z=8)
        samples_per_frame_ = 2;  // 每帧每像素多采样次数，默认为2，能显著降低闪烁
        focused_entity_id_ = -1; // no focus locked initially

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
    camera_object.padding[0] = 0;
    camera_object_buffer_->UploadData(&camera_object, sizeof(CameraObject));

    core_->CreateImage(window_->GetWidth(), window_->GetHeight(), grassland::graphics::IMAGE_FORMAT_R32G32B32A32_SFLOAT,
        &color_image_);
    
    // Create entity ID buffer for accurate picking (R32_SINT to store entity indices)
    core_->CreateImage(window_->GetWidth(), window_->GetHeight(), grassland::graphics::IMAGE_FORMAT_R32_SINT,
        &entity_id_image_);
    core_->CreateImage(window_->GetWidth(), window_->GetHeight(), grassland::graphics::IMAGE_FORMAT_R32_SFLOAT,
        &depth_image_);

    core_->CreateShader(GetShaderCode("shaders/shader.hlsl"), "RayGenMain", "lib_6_3", &raygen_shader_);
    core_->CreateShader(GetShaderCode("shaders/shader.hlsl"), "MissMain", "lib_6_3", &miss_shader_);
    core_->CreateShader(GetShaderCode("shaders/shader.hlsl"), "ClosestHitMain", "lib_6_3", &closest_hit_shader_);
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
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_IMAGE, 16);                  // space10 - texture array
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_SAMPLER, 1);                 // space10 - texture sampler
    program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_WRITABLE_IMAGE, 1);          // space12 - depth image
    // 暂时注释掉全局几何缓冲区绑定
    // program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space9 - global vertices
    // program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space10 - global normals
    // program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space11 - global indices
    // program_->AddResourceBinding(grassland::graphics::RESOURCE_TYPE_STORAGE_BUFFER, 1);          // space12 - entity offsets
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
    
    // Don't call TerminateImGui - let the window destructor handle it
    // Just reset window which will clean everything up properly
    window_.reset();
}

void Application::UpdateHoveredEntity() {
    // Only detect hover when camera is disabled (cursor visible)
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

void Application::OnUpdate() {
    if (window_->ShouldClose()) {
        window_->CloseWindow();
        alive_ = false;
        return;  // Exit update immediately after closing
    }
    if (alive_) {
        // Process keyboard input to move camera
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
        }

        
        // Detect camera state change and reset accumulation if camera started moving
        if (camera_enabled_ != last_camera_enabled_) {
            if (camera_enabled_) {
                // Camera just got enabled - will be moving, so prepare for reset when it stops
                grassland::LogInfo("Camera enabled - accumulation will reset when camera stops");
            } else {
                // Camera just got disabled - reset accumulation for new stationary view
                film_->Reset();
                grassland::LogInfo("Camera disabled - starting accumulation");
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
        current_camera_object.padding[0] = 0;
        camera_object_buffer_->UploadData(&current_camera_object, sizeof(CameraObject));
        // --------------- 修改结束 ---------------


        // Optional: Animate entities
        // For now, entities are static. You can update their transforms and call:
        // scene_->UpdateInstances();
    }
}

void Application::ApplyHoverHighlight(grassland::graphics::Image* image) {
    // Apply hover highlighting by modifying pixels where entity ID matches hovered entity
    // This is done as a CPU-side post-process so it doesn't affect accumulation
    
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

void Application::SaveAccumulatedOutput(const std::string& filename) {
    // Save the accumulated output image to a PNG file (without hover highlighting)
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
    }

    ImGui::Spacing();

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
        
        ImGui::Text("Base Color:");
        ImGui::ColorEdit3("##base_color", &mat.base_color[0], ImGuiColorEditFlags_NoInputs);
        ImGui::Text("  RGB: (%.2f, %.2f, %.2f)", mat.base_color.r, mat.base_color.g, mat.base_color.b);
        
        ImGui::Text("Roughness: %.2f", mat.roughness);
        ImGui::Text("Metallic: %.2f", mat.metallic);
        
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
    } else {
        ImGui::TextDisabled("No entity selected");
        ImGui::Spacing();
        ImGui::TextWrapped("Hover over an entity to highlight it, then left-click to select. Or use the dropdown above.");
    }
    
    ImGui::End();
}

void Application::OnRender() {
    // Don't render if window is closing
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
    
    // When camera is disabled, increment sample count and use accumulated image
    grassland::graphics::Image* display_image = color_image_.get();
    if (!camera_enabled_) {
        film_->IncrementSampleCount();
        film_->DevelopToOutput();
        display_image = film_->GetOutputImage();
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
