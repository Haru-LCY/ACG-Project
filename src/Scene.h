#pragma once
#include "long_march.h"
#include "Entity.h"
#include "Material.h"
#include <vector>
#include <memory>

// Entity offset information for global buffers
struct EntityOffset {
    uint32_t vertex_offset;  // Starting vertex index in global buffer
    uint32_t index_offset;   // Starting index in global buffer
    uint32_t padding[2];     // Align to 16 bytes for GPU
};

// KDT节点结构体（用于GPU，与HLSL中的结构体对应）
struct KDTNodeGPU {
    glm::vec3 aabb_min;      // AABB最小值
    glm::vec3 aabb_max;      // AABB最大值
    int32_t split_axis;      // 分割轴：0=X, 1=Y, 2=Z, -1=叶子节点
    float split_pos;         // 分割位置
    int32_t left_child_idx;  // 左子节点索引（-1表示无子节点）
    int32_t right_child_idx; // 右子节点索引（-1表示无子节点）
    int32_t entity_start_idx; // 实体索引列表起始位置（仅在叶子节点有效）
    int32_t entity_count;    // 实体数量（仅在叶子节点有效）
    uint32_t mask;           // 该节点对应的instance mask
    uint32_t padding;        // 对齐填充
};

// KDT信息结构体（用于GPU，传递节点数量）
struct KDTInfo {
    uint32_t num_nodes;      // KDT节点数量
    uint32_t padding[3];     // 对齐填充（确保16字节对齐）
};

// KDT节点结构体（用于CPU构建）
struct KDTNode {
    grassland::AABB aabb;                    // 包围盒
    int split_axis;                         // 分割轴：0=X, 1=Y, 2=Z, -1=叶子节点
    float split_pos;                         // 分割位置
    int left_child_idx;                     // 左子节点索引
    int right_child_idx;                     // 右子节点索引
    std::vector<uint32_t> entity_indices;   // 该节点包含的实体索引列表
    uint32_t mask;                           // 该节点对应的instance mask
};

// Scene manages a collection of entities and builds the TLAS
class Scene {
public:
    Scene(grassland::graphics::Core* core);
    ~Scene();

    // Add an entity to the scene
    void AddEntity(std::shared_ptr<Entity> entity);

    // Remove all entities
    void Clear();

    // Build/rebuild the TLAS from all entities
    void BuildAccelerationStructures();

    // Update TLAS instances (e.g., for animation)
    void UpdateInstances();

    // Get the TLAS for rendering
    grassland::graphics::AccelerationStructure* GetTLAS() const { return tlas_.get(); }
    
    // Get KDT nodes buffer for GPU traversal
    grassland::graphics::Buffer* GetKDTNodesBuffer() const { return kdt_nodes_buffer_.get(); }
    
    // Get KDT info buffer (contains node count)
    grassland::graphics::Buffer* GetKDTInfoBuffer() const { return kdt_info_buffer_.get(); }
    
    // Debug: 输出所有KDT节点的AABB信息
    void DebugPrintKDTNodes() const;
    // Debug: 测试光线与哪些AABB相交，返回相交信息
    struct KDTIntersectionInfo {
        int node_idx;
        bool is_leaf;
        float t_hit;
        glm::vec3 aabb_min;
        glm::vec3 aabb_max;
        int split_axis;
        float split_pos;
        uint32_t mask;
        int entity_count;
    };
    std::vector<KDTIntersectionInfo> DebugTestRayAABBIntersection(const glm::vec3& rayOrigin, const glm::vec3& rayDir, float tMin, float tMax) const;
    
    // Get number of KDT nodes
    size_t GetKDTNodeCount() const { return kdt_nodes_.size(); }

    // Get materials buffer for all entities
    grassland::graphics::Buffer* GetMaterialsBuffer() const { return materials_buffer_.get(); }

    // Get global geometry buffers for raytracing
    grassland::graphics::Buffer* GetGlobalVertexBuffer() const { return global_vertex_buffer_.get(); }
    grassland::graphics::Buffer* GetGlobalNormalBuffer() const { return global_normal_buffer_.get(); }
    grassland::graphics::Buffer* GetGlobalIndexBuffer() const { return global_index_buffer_.get(); }
    
    // Get entity offset buffer (stores vertex/index offsets for each entity)
    grassland::graphics::Buffer* GetEntityOffsetsBuffer() const { return entity_offsets_buffer_.get(); }
    
    // Get texture array for raytracing
    const std::vector<grassland::graphics::Image*>& GetTextures() const { return textures_; }
    size_t GetTextureCount() const { return textures_.size(); }

    // Get all entities
    const std::vector<std::shared_ptr<Entity>>& GetEntities() const { return entities_; }

    // Get number of entities
    size_t GetEntityCount() const { return entities_.size(); }

    // Update materials buffer data on GPU from CPU-side materials
    void UpdateMaterials();

private:
    void UpdateMaterialsBuffer();
    void BuildGlobalGeometryBuffers();
    void CollectTextures();
    
    // KDT相关函数
    void BuildKDT();
    int BuildKDTRecursive(std::vector<std::pair<grassland::AABB, uint32_t>>& entities_with_aabb,
                          int start_idx, int end_idx, int cut_dim, int node_idx, int depth = 0);
    int CountNodes(int node_idx);  // 辅助函数：找到子树中最大的节点索引
    int FindMaxNodeIndex(int node_idx);  // 辅助函数：找到子树中最大的节点索引（别名）
    grassland::AABB ComputeEntityAABB(uint32_t entity_idx);
    void BuildTLASWithKDT();

    grassland::graphics::Core* core_;
    std::vector<std::shared_ptr<Entity>> entities_;
    std::unique_ptr<grassland::graphics::AccelerationStructure> tlas_;
    std::unique_ptr<grassland::graphics::Buffer> materials_buffer_;
    
    // Global geometry buffers for all entities combined
    std::unique_ptr<grassland::graphics::Buffer> global_vertex_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> global_normal_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> global_index_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> entity_offsets_buffer_;
    
    // Texture array (raw pointers owned by entities)
    std::vector<grassland::graphics::Image*> textures_;
    
    // KDT树相关
    std::vector<KDTNode> kdt_nodes_;                                    // KDT节点数组（CPU端）
    std::unique_ptr<grassland::graphics::Buffer> kdt_nodes_buffer_;     // KDT节点buffer（GPU端）
    std::unique_ptr<grassland::graphics::Buffer> kdt_info_buffer_;      // KDT信息buffer（GPU端，包含节点数量）
    std::vector<KDTNodeGPU> kdt_nodes_gpu_;                             // KDT节点数组（GPU格式）
};

