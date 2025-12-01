#pragma once
#include "long_march.h"
#include "Entity.h"
#include "Material.h"
#include <vector>
#include <memory>

// 纹理数组最大数量（必须与Shader端保持一致）
// 注意：此值必须与 src/shaders/common.hlsl 中的 MAX_TEXTURES 宏定义保持一致
constexpr size_t MAX_TEXTURES = 64;

// 实体偏移信息结构体（用于全局缓冲区）
// Entity offset information for global buffers
struct EntityOffset {
    uint32_t vertex_offset;  // 在全局缓冲区中的起始顶点索引
    uint32_t index_offset;    // 在全局缓冲区中的起始索引
    uint32_t padding[2];      // 填充以对齐到16字节（GPU要求）
};

// Scene类：管理场景中的所有实体，构建顶层加速结构（TLAS）
// Scene manages a collection of entities and builds the TLAS
class Scene {
public:
    // 构造函数：创建场景对象
    // core: 图形核心对象指针
    Scene(grassland::graphics::Core* core);
    
    // 析构函数：清理所有资源
    ~Scene();

    // 向场景添加实体
    // entity: 实体共享指针
    // 注意：添加时会自动构建实体的BLAS
    void AddEntity(std::shared_ptr<Entity> entity);

    // 清除场景中的所有实体
    void Clear();

    // 构建/重建顶层加速结构（TLAS）
    // 功能：从所有实体构建TLAS，并构建全局几何缓冲区
    void BuildAccelerationStructures();

    // 更新TLAS实例（例如用于动画）
    // 功能：更新所有实体的变换矩阵，重建TLAS实例
    void UpdateInstances();

    // ========== Getter方法 ==========
    // 获取TLAS指针（用于渲染）
    grassland::graphics::AccelerationStructure* GetTLAS() const { return tlas_.get(); }

    // 获取所有实体的材质缓冲区
    grassland::graphics::Buffer* GetMaterialsBuffer() const { return materials_buffer_.get(); }

    // 获取全局几何缓冲区（用于光线追踪）
    grassland::graphics::Buffer* GetGlobalVertexBuffer() const { return global_vertex_buffer_.get(); }
    grassland::graphics::Buffer* GetGlobalNormalBuffer() const { return global_normal_buffer_.get(); }
    grassland::graphics::Buffer* GetGlobalIndexBuffer() const { return global_index_buffer_.get(); }
    
    // 获取实体偏移缓冲区（存储每个实体的顶点/索引偏移）
    grassland::graphics::Buffer* GetEntityOffsetsBuffer() const { return entity_offsets_buffer_.get(); }
    
    // 获取实体速度缓冲区（用于运动模糊）
    grassland::graphics::Buffer* GetVelocitiesBuffer() const { return velocities_buffer_.get(); }
    
    // 获取纹理数组（用于光线追踪）
    const std::vector<grassland::graphics::Image*>& GetTextures() const { return textures_; }
    // 获取纹理数量
    size_t GetTextureCount() const { return textures_.size(); }

    // 获取所有实体的引用
    const std::vector<std::shared_ptr<Entity>>& GetEntities() const { return entities_; }

    // 获取实体数量
    size_t GetEntityCount() const { return entities_.size(); }

    // 更新材质缓冲区数据（从CPU端材质更新到GPU）
    void UpdateMaterials();

private:
    // ========== 私有辅助函数 ==========
    // 更新材质缓冲区（内部实现）
    void UpdateMaterialsBuffer();
    // 构建全局几何缓冲区（合并所有实体的几何数据）
    void BuildGlobalGeometryBuffers();
    // 收集所有实体的纹理
    void CollectTextures();

    grassland::graphics::Core* core_;                              // 图形核心对象指针
    std::vector<std::shared_ptr<Entity>> entities_;                // 实体列表
    std::unique_ptr<grassland::graphics::AccelerationStructure> tlas_;  // 顶层加速结构
    
    std::unique_ptr<grassland::graphics::Buffer> materials_buffer_;  // 材质缓冲区
    
    // 全局几何缓冲区（合并所有实体的几何数据）
    std::unique_ptr<grassland::graphics::Buffer> global_vertex_buffer_;  // 全局顶点缓冲区
    std::unique_ptr<grassland::graphics::Buffer> global_normal_buffer_; // 全局法线缓冲区
    std::unique_ptr<grassland::graphics::Buffer> global_index_buffer_;  // 全局索引缓冲区
    std::unique_ptr<grassland::graphics::Buffer> entity_offsets_buffer_;  // 实体偏移缓冲区
    
    // 运动模糊：实体速度缓冲区
    std::unique_ptr<grassland::graphics::Buffer> velocities_buffer_;
    
    // 纹理数组（原始指针，所有权属于实体）
    std::vector<grassland::graphics::Image*> textures_;
};

