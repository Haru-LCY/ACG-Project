#pragma once
#include "long_march.h"
#include "Scene.h"
#include "Film.h"
#include <memory>

struct CameraObject {
    glm::mat4 screen_to_camera;
    glm::mat4 camera_to_world;
};

class Application {
public:
    Application(grassland::graphics::BackendAPI api = grassland::graphics::BACKEND_API_DEFAULT);

    ~Application();

    void OnInit();
    void OnClose();
    void OnUpdate();
    void OnRender();
    void UpdateHoveredEntity(); // Update which entity the mouse is hovering over
    void RenderEntityPanel(); // Render entity inspector panel on the right

    bool IsAlive() const {
        return alive_;
    }

private:
    // Core graphics objects
    std::shared_ptr<grassland::graphics::Core> core_;
    std::unique_ptr<grassland::graphics::Window> window_;

    // Scene management
    std::unique_ptr<Scene> scene_;
    
    // Film for accumulation
    std::unique_ptr<Film> film_;

    // Camera
    std::unique_ptr<grassland::graphics::Buffer> camera_object_buffer_;
    
    // Hover info buffer
    struct HoverInfo {
        int hovered_entity_id;
    };
    std::unique_ptr<grassland::graphics::Buffer> hover_info_buffer_;
    
    // Point lights buffer
    struct PointLight {
        glm::vec3 position;     // 光源位置
        float strength;         // 光源强度
        glm::vec3 color;        // 光源颜色
        float radius;           // 光源半径（预留用于软阴影）
    };
    std::unique_ptr<grassland::graphics::Buffer> point_lights_buffer_;
    std::vector<PointLight> point_lights_;  // 点光源数组

    // Area lights buffer
    struct AreaLight {
        glm::vec3 position;     // 光源中心位置
        float strength;         // 总辐射功率（单位：瓦特）
        glm::vec3 color;        // 光源颜色 (RGB, 范围0-1)
        float width;            // 光源宽度（米）
        glm::vec3 direction;    // 光源法线方向（归一化）
        float height;           // 光源高度（米）
        glm::vec3 u_axis;       // 宽度方向轴（归一化）
        float pad1;
        glm::vec3 v_axis;       // 高度方向轴（归一化）
        float pad2;
    };
    std::unique_ptr<grassland::graphics::Buffer> area_lights_buffer_;
    std::vector<AreaLight> area_lights_;  // 面光源数组

    // Shaders
    std::unique_ptr<grassland::graphics::Shader> raygen_shader_;
    std::unique_ptr<grassland::graphics::Shader> miss_shader_;
    std::unique_ptr<grassland::graphics::Shader> closest_hit_shader_;

    // Rendering
    std::unique_ptr<grassland::graphics::Image> color_image_;
    std::unique_ptr<grassland::graphics::Image> entity_id_image_; // Entity ID buffer for accurate picking
    std::unique_ptr<grassland::graphics::RayTracingProgram> program_;
    bool alive_{ false };

    void ProcessInput(); // Helper function for keyboard input


    glm::vec3 camera_pos_;
    glm::vec3 camera_front_;
    glm::vec3 camera_up_;
    float camera_speed_;


    void OnMouseMove(double xpos, double ypos); // Mouse event handler
    void OnMouseButton(int button, int action, int mods, double xpos, double ypos); // Mouse button event handler
    void RenderInfoOverlay(); // Render the info overlay
    void ApplyHoverHighlight(grassland::graphics::Image* image); // Apply hover highlighting as post-process
    void SaveAccumulatedOutput(const std::string& filename); // Save accumulated output to PNG file

    float yaw_;
    float pitch_;
    float last_x_;
    float last_y_;
    float mouse_sensitivity_;
    bool first_mouse_; // Prevents camera jump on first mouse input
    bool camera_enabled_; // Whether camera movement is enabled
    bool last_camera_enabled_; // Track camera state changes to reset accumulation
    bool ui_hidden_; // Whether UI panels are hidden (Tab key toggle)
    
    // Mouse hovering
    double mouse_x_;
    double mouse_y_;
    int hovered_entity_id_; // -1 if no entity hovered
    glm::vec4 hovered_pixel_color_; // Color value at hovered pixel
    
    // Entity selection
    int selected_entity_id_; // -1 if no entity selected

    // 添加这些成员变量用于检测相机变化
    glm::mat4 prev_camera_to_world_;
    glm::mat4 prev_screen_to_camera_;
    bool has_prev_camera_ = false;

    // 辅助函数：比较两个矩阵是否不同
    bool MatrixChanged(const glm::mat4& a, const glm::mat4& b, float epsilon = 1e-5f) {
      for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
          if (fabs(a[i][j] - b[i][j]) > epsilon)
            return true;
        }
      }
      return false;
    }
};
