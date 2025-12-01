#pragma once
#include "long_march.h"
#include "Scene.h"
#include "Film.h"
#include <memory>

// 相机对象结构体（传递给shader的相机参数）
struct CameraObject {
    glm::mat4 screen_to_camera;  // 屏幕空间到相机空间的变换矩阵
    glm::mat4 camera_to_world;    // 相机空间到世界空间的变换矩阵
    float aperture;                // 光圈大小（模拟真实相机光圈，0=无景深效果）
    float focus_distance;         // 焦距（聚焦平面距离，单位：米）
    float exposure;               // 成像曝光补偿（乘数）
    int samples_per_pixel;        // 每帧每像素发射的样本数，用于减少闪烁
    int debug_mode;               // 调试模式标志
    int debug_point_index;        // 调试点光源索引
    int msaa_mode;                // MSAA模式: 0=Off, 1=2x, 2=4x, 3=8x, 4=Random
    int accumulated_frames;       // 累积帧数（用于时间累积MSAA）
    // 运动模糊参数
    int motion_blur_mode;         // 运动模糊模式: 0=Off, 1=Camera, 2=Object, 3=Radial, 4=Directional
    float motion_blur_intensity;  // 运动模糊强度
    glm::vec2 motion_blur_direction; // 方向性模糊的方向向量
    // 光源数量
    int num_point_lights;  // 点光源数量
    int num_area_lights;   // 面光源数量
};

// Skybox / Environment Map 信息 (与 shader 中的定义匹配)
struct SkyboxInfo {
    // 程序化天空颜色
    glm::vec3 zenith_color;       // 天顶颜色
    float has_environment_map;    // 是否有环境贴图 (>0.5 = true)
    
    glm::vec3 horizon_color;      // 地平线颜色
    float environment_intensity;  // 环境光强度
    
    glm::vec3 ground_color;       // 地面颜色
    float environment_rotation;   // 环境贴图旋转角度（弧度）
    
    // 太阳/方向光设置
    glm::vec3 sun_direction;      // 太阳方向（归一化）
    float sun_intensity;          // 太阳强度
    
    glm::vec3 sun_color;          // 太阳颜色
    float sun_angular_radius;     // 太阳角半径（弧度）
};

// MSAA 模式枚举 (与 shader 中的定义匹配)
enum MSAAMode {
    MSAA_MODE_OFF = 0,      // 关闭 MSAA
    MSAA_MODE_2X = 1,       // 2x MSAA
    MSAA_MODE_4X = 2,       // 4x MSAA
    MSAA_MODE_8X = 3,       // 8x MSAA
    MSAA_MODE_RANDOM = 4    // 随机抖动
};

// Application类：主应用程序类，管理整个渲染管线
class Application {
public:
    // 构造函数：创建应用程序实例
    // api: 图形API后端（D3D12或Vulkan）
    Application(grassland::graphics::BackendAPI api = grassland::graphics::BACKEND_API_DEFAULT);

    // 析构函数：清理资源
    ~Application();

    // 初始化应用程序（创建窗口、场景、shader等）
    void OnInit();
    
    // 关闭应用程序（清理资源）
    void OnClose();
    
    // 更新应用程序状态（每帧调用，处理输入、更新相机等）
    void OnUpdate();
    
    // 渲染一帧（每帧调用）
    void OnRender();
    
    // 更新鼠标悬停的实体（检测鼠标位置下的实体）
    void UpdateHoveredEntity();
    
    // 渲染实体检查器面板（右侧UI面板）
    void RenderEntityPanel();

    // 检查应用程序是否仍在运行
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

    // Skybox / Environment Map
    static constexpr bool USE_HDR_SKYBOX = true;  // 改为 false 可禁用 HDR skybox
    static constexpr const char* HDR_SKYBOX_PATH = "textures/environment.hdr";  // HDR 环境贴图路径
    
    std::unique_ptr<grassland::graphics::Buffer> skybox_info_buffer_;
    std::unique_ptr<grassland::graphics::Image> environment_map_;
    std::unique_ptr<grassland::graphics::Sampler> environment_sampler_;
    SkyboxInfo skybox_info_;
    bool skybox_need_upload_ = false;

    // Shaders
    std::unique_ptr<grassland::graphics::Shader> raygen_shader_;
    std::unique_ptr<grassland::graphics::Shader> miss_shader_;
    std::unique_ptr<grassland::graphics::Shader> closest_hit_shader_;

    // Rendering
    std::unique_ptr<grassland::graphics::Image> color_image_;
    std::unique_ptr<grassland::graphics::Image> entity_id_image_; // Entity ID buffer for accurate picking
    std::unique_ptr<grassland::graphics::Image> depth_image_; // Depth buffer for pick-based autofocus
    std::unique_ptr<grassland::graphics::RayTracingProgram> program_;
    std::unique_ptr<grassland::graphics::Sampler> texture_sampler_; // Texture sampler
    bool alive_{ false };

    // ========== 私有辅助函数 ==========
    // 处理键盘输入（辅助函数）
    void ProcessInput();
    
    // 初始化天空盒（HDR或程序化）
    void InitializeSkybox();
    
    // 创建默认后备环境贴图（简单的渐变天空）
    void CreateDefaultEnvironmentMap();


    glm::vec3 camera_pos_;
    glm::vec3 camera_front_;
    glm::vec3 camera_up_;
    float camera_speed_;


    // 鼠标移动事件处理函数
    void OnMouseMove(double xpos, double ypos);
    
    // 鼠标按钮事件处理函数
    void OnMouseButton(int button, int action, int mods, double xpos, double ypos);
    
    // 渲染信息覆盖层（左侧UI面板）
    void RenderInfoOverlay();
    
    // 应用悬停高亮效果（后处理）
    // image: 要处理的图像
    void ApplyHoverHighlight(grassland::graphics::Image* image);
    
    // 保存累积输出到PNG文件
    // filename: 输出文件名
    void SaveAccumulatedOutput(const std::string& filename);

    float yaw_;
    float pitch_;
    float last_x_;
    float last_y_;
    float mouse_sensitivity_;
    bool first_mouse_; // Prevents camera jump on first mouse input
    bool camera_enabled_; // Whether camera movement is enabled
    bool last_camera_enabled_; // Track camera state changes to reset accumulation
    bool ui_hidden_; // Whether UI panels are hidden (Tab key toggle)
    
    // Depth of Field parameters
    float aperture_;        // 光圈大小 (0 = 无景深效果)
    float focus_distance_;  // 焦距 (聚焦平面距离)
    int samples_per_frame_; // 每帧为每像素发射的样本数量（用于降低闪烁）
    float exposure_;        // 全局曝光调整 (shader 内应用)
    bool lights_need_upload_ = false; // Set true when UI changes light params
    
    // MSAA 参数
    int msaa_mode_;         // 当前 MSAA 模式
    int accumulated_frames_; // 累积帧计数（用于时间累积 MSAA）
    
    // Motion Blur 参数
    int motion_blur_mode_;        // 运动模糊模式
    float motion_blur_intensity_; // 运动模糊强度
    glm::vec2 motion_blur_direction_; // 方向性模糊的方向
    
    // Mouse hovering
    double mouse_x_;
    double mouse_y_;
    int hovered_entity_id_; // -1 if no entity hovered
    glm::vec4 hovered_pixel_color_; // Color value at hovered pixel
    int hover_candidate_id_; // 临时候选id
    int hover_consistency_count_; // 候选id连续帧计数
    int hover_consistency_threshold_; // 需要连续多少帧才确认（默认2帧）
    
    // Entity selection
    int selected_entity_id_; // -1 if no entity selected
    int focused_entity_id_; // -1 if no focus locked to an entity

    // 添加这些成员变量用于检测相机变化
    glm::mat4 prev_camera_to_world_;
    glm::mat4 prev_screen_to_camera_;
    bool has_prev_camera_ = false;

    // 辅助函数：比较两个矩阵是否不同（用于检测相机移动）
    // a, b: 要比较的两个矩阵
    // epsilon: 容差值（默认1e-5）
    // 返回：如果矩阵不同返回true，否则返回false
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
