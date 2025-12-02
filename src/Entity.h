#pragma once
#include "long_march.h"
#include "Material.h"

// Entity类：表示场景中的一个网格实例，包含材质和变换信息
// Entity represents a mesh instance with a material and transform
class Entity {
public:
    // 构造函数：创建实体对象
    // obj_file_path: OBJ模型文件路径
    // material: 材质属性（默认使用默认材质）
    // transform: 世界空间变换矩阵（默认为单位矩阵）
    // texture_path: 纹理文件路径（可选）
    Entity(const std::string& obj_file_path, 
           const Material& material = Material(),
           const glm::mat4& transform = glm::mat4(1.0f),
           const std::string& texture_path = "");

    // 析构函数：清理资源
    ~Entity();

    // 从OBJ文件加载网格数据
    // obj_file_path: OBJ文件路径
    // 返回：成功返回true，失败返回false
    bool LoadMesh(const std::string& obj_file_path);
    
    // 从文件加载纹理
    // core: 图形核心对象指针
    // texture_path: 纹理文件路径
    // 返回：成功返回true，失败返回false
    bool LoadTexture(grassland::graphics::Core* core, const std::string& texture_path);

    // ========== Getter方法 ==========
    // 获取顶点缓冲区指针
    grassland::graphics::Buffer* GetVertexBuffer() const { return vertex_buffer_.get(); }
    // 获取索引缓冲区指针
    grassland::graphics::Buffer* GetIndexBuffer() const { return index_buffer_.get(); }
    // 获取法线缓冲区指针
    grassland::graphics::Buffer* GetNormalBuffer() const { return normal_buffer_.get(); }
    // 获取纹理图像指针
    grassland::graphics::Image* GetTexture() const { return texture_.get(); }
    // 获取材质引用
    const Material& GetMaterial() const { return material_; }
    // 获取变换矩阵引用
    const glm::mat4& GetTransform() const { return transform_; }
    // 获取底层加速结构（BLAS）指针
    grassland::graphics::AccelerationStructure* GetBLAS() const { return blas_.get(); }
    // 检查是否有纹理
    bool HasTexture() const { return texture_ != nullptr; }
    
    // 获取物体速度（用于运动模糊）
    // 返回：世界空间速度向量（单位：单位/帧）
    const glm::vec3& GetVelocity() const { return velocity_; }

    // ========== Setter方法 ==========
    // 设置材质
    void SetMaterial(const Material& material) { material_ = material; }
    // 设置变换矩阵
    void SetTransform(const glm::mat4& transform) { transform_ = transform; }
    // 设置纹理ID（用于纹理数组索引）
    void SetTextureId(int id) { material_.texture_id = id; }
    
    // 设置物体速度（用于运动模糊）
    // velocity: 世界空间速度向量（单位：单位/帧）
    void SetVelocity(const glm::vec3& velocity) { velocity_ = velocity; }

    // 为此实体的网格构建底层加速结构（BLAS）
    // core: 图形核心对象指针
    // 注意：此函数会创建顶点、索引、法线缓冲区，并构建BLAS
    void BuildBLAS(grassland::graphics::Core* core);

    // 检查网格是否已成功加载
    // 返回：已加载返回true，否则返回false
    bool IsValid() const { return mesh_loaded_; }

    // 获取网格数据引用（用于构建全局缓冲区）
    // 返回：网格数据常量引用
    const grassland::Mesh<float>& GetMesh() const { return mesh_; }

private:
    grassland::Mesh<float> mesh_;              // 网格数据
    Material material_;                        // 材质属性
    glm::mat4 transform_;                      // 世界空间变换矩阵
    std::string texture_path_;                 // 纹理文件路径

    std::unique_ptr<grassland::graphics::Buffer> vertex_buffer_;    // 顶点缓冲区
    std::unique_ptr<grassland::graphics::Buffer> index_buffer_;     // 索引缓冲区
    std::unique_ptr<grassland::graphics::Buffer> normal_buffer_;    // 法线缓冲区
    std::unique_ptr<grassland::graphics::Image> texture_;           // 纹理图像
    std::unique_ptr<grassland::graphics::AccelerationStructure> blas_;  // 底层加速结构

    bool mesh_loaded_;                         // 网格是否已加载标志
    
    // 运动模糊：物体速度（世界空间，单位：单位/帧）
    glm::vec3 velocity_ = glm::vec3(0.0f);
};

