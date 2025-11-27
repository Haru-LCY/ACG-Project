#include "Scene.h"
#include <algorithm>
#include <cmath>
#include <functional>

Scene::Scene(grassland::graphics::Core* core)
    : core_(core) {
}

Scene::~Scene() {
    Clear();
}

void Scene::AddEntity(std::shared_ptr<Entity> entity) {
    if (!entity || !entity->IsValid()) {
        grassland::LogError("Cannot add invalid entity to scene");
        return;
    }

    // Build BLAS for the entity
    entity->BuildBLAS(core_);
    
    entities_.push_back(entity);
    grassland::LogInfo("Added entity to scene (total: {})", entities_.size());
}

void Scene::Clear() {
    entities_.clear();
    tlas_.reset();
    materials_buffer_.reset();
    global_vertex_buffer_.reset();
    global_normal_buffer_.reset();
    global_index_buffer_.reset();
    entity_offsets_buffer_.reset();
    kdt_nodes_.clear();
    kdt_nodes_buffer_.reset();
    kdt_info_buffer_.reset();
    kdt_nodes_gpu_.clear();
}

void Scene::BuildAccelerationStructures() {
    if (entities_.empty()) {
        grassland::LogWarning("No entities to build acceleration structures");
        return;
    }

    // 构建KDT树
    BuildKDT();
    
    // 使用KDT分组构建TLAS
    BuildTLASWithKDT();

    // Build global geometry buffers
    BuildGlobalGeometryBuffers();
    
    // Collect textures from entities
    CollectTextures();

    // Update materials buffer (must be done after collecting textures to set texture IDs)
    UpdateMaterialsBuffer();
}

void Scene::UpdateInstances() {
    if (!tlas_ || entities_.empty()) {
        return;
    }

    // Recreate instances with updated transforms
    std::vector<grassland::graphics::RayTracingInstance> instances;
    instances.reserve(entities_.size());

    for (size_t i = 0; i < entities_.size(); ++i) {
        auto& entity = entities_[i];
        if (entity->GetBLAS()) {
            // Convert mat4 to mat4x3
            glm::mat4x3 transform_3x4 = glm::mat4x3(entity->GetTransform());
            
            auto instance = entity->GetBLAS()->MakeInstance(
                transform_3x4,
                static_cast<uint32_t>(i),
                0xFF,
                0,
                grassland::graphics::RAYTRACING_INSTANCE_FLAG_NONE
            );
            instances.push_back(instance);
        }
    }

    // Update TLAS
    tlas_->UpdateInstances(instances);
}

void Scene::UpdateMaterials() {
    // Expose private UpdateMaterialsBuffer() functionality
    UpdateMaterialsBuffer();
}

void Scene::UpdateMaterialsBuffer() {
    if (entities_.empty()) {
        return;
    }

    // Collect all materials
    std::vector<Material> materials;
    materials.reserve(entities_.size());

    for (const auto& entity : entities_) {
        materials.push_back(entity->GetMaterial());
    }

    // Create/update materials buffer
    size_t buffer_size = materials.size() * sizeof(Material);
    
    if (!materials_buffer_) {
        core_->CreateBuffer(buffer_size, 
                          grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                          &materials_buffer_);
    }
    
    materials_buffer_->UploadData(materials.data(), buffer_size);
    grassland::LogInfo("Updated materials buffer with {} materials", materials.size());
}

void Scene::BuildGlobalGeometryBuffers() {
    if (entities_.empty()) {
        return;
    }

    // Collect all vertices, normals, and indices from all entities
    std::vector<glm::vec3> all_vertices;
    std::vector<glm::vec3> all_normals;
    std::vector<uint32_t> all_indices;
    std::vector<EntityOffset> entity_offsets;
    
    uint32_t current_vertex_offset = 0;
    uint32_t current_index_offset = 0;
    
    for (const auto& entity : entities_) {
        if (!entity->IsValid()) continue;
        
        // Store offset for this entity
        EntityOffset offset;
        offset.vertex_offset = current_vertex_offset;
        offset.index_offset = current_index_offset;
        offset.padding[0] = 0;
        offset.padding[1] = 0;
        entity_offsets.push_back(offset);
        
        // Get mesh data from entity
        const auto& mesh = entity->GetMesh();
        size_t num_vertices = mesh.NumVertices();
        size_t num_indices = mesh.NumIndices();
        
        // Add vertices
        const glm::vec3* positions = reinterpret_cast<const glm::vec3*>(mesh.Positions());
        for (size_t i = 0; i < num_vertices; ++i) {
            all_vertices.push_back(positions[i]);
        }
        
        // Add normals (use geometric normals if not available)
        const glm::vec3* normals = reinterpret_cast<const glm::vec3*>(mesh.Normals());
        if (normals) {
            for (size_t i = 0; i < num_vertices; ++i) {
                all_normals.push_back(normals[i]);
            }
        } else {
            // Generate placeholder normals (will be computed geometrically in shader)
            for (size_t i = 0; i < num_vertices; ++i) {
                all_normals.push_back(glm::vec3(0.0f, 1.0f, 0.0f)); // Placeholder
            }
        }
        
        // Add indices (no offset needed here since we're building a continuous buffer)
        const uint32_t* indices = mesh.Indices();
        for (size_t i = 0; i < num_indices; ++i) {
            all_indices.push_back(indices[i] + current_vertex_offset);
        }
        
        current_vertex_offset += static_cast<uint32_t>(num_vertices);
        current_index_offset += static_cast<uint32_t>(num_indices);
    }
    
    // Create global vertex buffer
    size_t vertex_buffer_size = all_vertices.size() * sizeof(glm::vec3);
    core_->CreateBuffer(vertex_buffer_size, 
                       grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                       &global_vertex_buffer_);
    global_vertex_buffer_->UploadData(all_vertices.data(), vertex_buffer_size);
    
    // Create global normal buffer
    size_t normal_buffer_size = all_normals.size() * sizeof(glm::vec3);
    core_->CreateBuffer(normal_buffer_size, 
                       grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                       &global_normal_buffer_);
    global_normal_buffer_->UploadData(all_normals.data(), normal_buffer_size);
    
    // Create global index buffer
    size_t index_buffer_size = all_indices.size() * sizeof(uint32_t);
    core_->CreateBuffer(index_buffer_size, 
                       grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                       &global_index_buffer_);
    global_index_buffer_->UploadData(all_indices.data(), index_buffer_size);
    
    // Create entity offsets buffer
    size_t offsets_buffer_size = entity_offsets.size() * sizeof(EntityOffset);
    core_->CreateBuffer(offsets_buffer_size, 
                       grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                       &entity_offsets_buffer_);
    entity_offsets_buffer_->UploadData(entity_offsets.data(), offsets_buffer_size);
    
    grassland::LogInfo("Built global geometry buffers: {} vertices, {} normals, {} indices, {} entities", 
                       all_vertices.size(), all_normals.size(), all_indices.size(), entity_offsets.size());
}

void Scene::CollectTextures() {
    textures_.clear();
    
    // Collect all unique textures from entities
    for (auto& entity : entities_) {
        if (entity->HasTexture()) {
            // Add texture to array and set texture ID in entity's material
            int texture_id = static_cast<int>(textures_.size());
            textures_.push_back(entity->GetTexture());
            entity->SetTextureId(texture_id);
            
            grassland::LogInfo("Assigned texture ID {} to entity with texture", texture_id);
        }
    }
    
    // Pad the texture array to the maximum size (16) to satisfy the static descriptor requirement in D3D12.
    // If we don't do this, the descriptor table will have uninitialized descriptors, causing a crash.
    if (!textures_.empty()) {
        size_t current_texture_count = textures_.size();
        const size_t max_textures = 16;
        if (current_texture_count < max_textures) {
            grassland::graphics::Image* fallback_texture = textures_[0]; // Use the first available texture as a fallback
            for (size_t i = current_texture_count; i < max_textures; ++i) {
                textures_.push_back(fallback_texture);
            }
            grassland::LogInfo("Padded texture array from {} to {} with a fallback texture.", current_texture_count, textures_.size());
        }
    }
    
    grassland::LogInfo("Collected {} textures from scene (padded to 16 for GPU binding)", textures_.size());
}

// 计算实体在世界空间中的AABB
grassland::AABB Scene::ComputeEntityAABB(uint32_t entity_idx) {
    if (entity_idx >= entities_.size()) {
        return grassland::AABB();
    }
    
    auto& entity = entities_[entity_idx];
    if (!entity->IsValid()) {
        return grassland::AABB();
    }
    
    const auto& mesh = entity->GetMesh();
    const glm::mat4& transform = entity->GetTransform();
    
    grassland::AABB aabb;
    
    // 获取mesh的顶点位置
    const glm::vec3* positions = reinterpret_cast<const glm::vec3*>(mesh.Positions());
    size_t num_vertices = mesh.NumVertices();
    
    // 将第一个顶点变换到世界空间并初始化AABB
    if (num_vertices > 0) {
        glm::vec4 world_pos = transform * glm::vec4(positions[0], 1.0f);
        aabb = grassland::AABB(grassland::Vector3<float>(world_pos.x, world_pos.y, world_pos.z));
    }
    
    // 遍历所有顶点，扩展AABB
    for (size_t i = 1; i < num_vertices; ++i) {
        glm::vec4 world_pos = transform * glm::vec4(positions[i], 1.0f);
        aabb.Expand(grassland::Vector3<float>(world_pos.x, world_pos.y, world_pos.z));
    }
    
    return aabb;
}

// 构建KDT树
void Scene::BuildKDT() {
    if (entities_.empty()) {
        grassland::LogInfo("[KDT] Starting KDT build: entity list is empty, skipping");
        return;
    }
    
    grassland::LogInfo("[KDT] ========== Starting KDT Build ==========");
    grassland::LogInfo("[KDT] Total entity count: {}", entities_.size());
    
    // 清空之前的KDT节点
    kdt_nodes_.clear();
    
    // 收集所有实体的AABB和索引
    std::vector<std::pair<grassland::AABB, uint32_t>> entities_with_aabb;
    entities_with_aabb.reserve(entities_.size());
    
    for (uint32_t i = 0; i < entities_.size(); ++i) {
        if (entities_[i]->IsValid() && entities_[i]->GetBLAS()) {
            grassland::AABB aabb = ComputeEntityAABB(i);
            entities_with_aabb.push_back({aabb, i});
            grassland::LogInfo("[KDT] Entity {}: AABB min=({:.3f}, {:.3f}, {:.3f}), max=({:.3f}, {:.3f}, {:.3f})",
                              i,
                              aabb.lower_bound[0], aabb.lower_bound[1], aabb.lower_bound[2],
                              aabb.upper_bound[0], aabb.upper_bound[1], aabb.upper_bound[2]);
        } else {
            grassland::LogWarning("[KDT] Entity {} is invalid or has no BLAS, skipping", i);
        }
    }
    
    if (entities_with_aabb.empty()) {
        grassland::LogWarning("[KDT] No valid entities for KDT construction");
        return;
    }
    
    grassland::LogInfo("[KDT] Valid entity count: {}", entities_with_aabb.size());
    
    // 预分配节点数组：最多需要 2 * num_entities - 1 个节点
    size_t max_nodes = entities_with_aabb.size() * 2 - 1;
    kdt_nodes_.resize(max_nodes);
    grassland::LogInfo("[KDT] Pre-allocated node array size: {} (max needed: 2*{} - 1 = {})", max_nodes, entities_with_aabb.size(), max_nodes);
    
    // 从X轴开始分割
    grassland::LogInfo("[KDT] Starting recursive build, splitting along X-axis, entity range [0, {})", entities_with_aabb.size());
    int root_idx = BuildKDTRecursive(entities_with_aabb, 0, static_cast<int>(entities_with_aabb.size()), 0, 0, 0);
    
    if (root_idx < 0) {
        grassland::LogError("[KDT] Build failed: invalid root node index ({})", root_idx);
        return;
    }
    
    grassland::LogInfo("[KDT] Recursive build completed, root node index: {}", root_idx);
    
    // 移除未使用的节点：找到实际使用的最大节点索引
    int max_node_idx = FindMaxNodeIndex(root_idx);
    if (max_node_idx < 0) {
        grassland::LogError("[KDT] Failed to find max node index");
        return;
    }
    size_t actual_nodes = static_cast<size_t>(max_node_idx) + 1;
    kdt_nodes_.resize(actual_nodes);
    grassland::LogInfo("[KDT] Actual nodes used: {} (from {} pre-allocated nodes, max node index: {})", actual_nodes, max_nodes, max_node_idx);
    
    // 输出树结构信息
    grassland::LogInfo("[KDT] ========== Tree Structure Info ==========");
    for (size_t i = 0; i < kdt_nodes_.size(); ++i) {
        const KDTNode& node = kdt_nodes_[i];
        if (node.split_axis == -1) {
            // 叶子节点
            grassland::LogInfo("[KDT] Node {} [LEAF]: AABB min=({:.3f}, {:.3f}, {:.3f}), max=({:.3f}, {:.3f}, {:.3f}), entity_count={}",
                              i,
                              node.aabb.lower_bound[0], node.aabb.lower_bound[1], node.aabb.lower_bound[2],
                              node.aabb.upper_bound[0], node.aabb.upper_bound[1], node.aabb.upper_bound[2],
                              node.entity_indices.size());
            if (!node.entity_indices.empty()) {
                std::string entity_list = "Entities: [";
                for (size_t j = 0; j < node.entity_indices.size(); ++j) {
                    entity_list += std::to_string(node.entity_indices[j]);
                    if (j < node.entity_indices.size() - 1) entity_list += ", ";
                }
                entity_list += "]";
                grassland::LogInfo("[KDT]   {}", entity_list);
            }
        } else {
            // 内部节点
            grassland::LogInfo("[KDT] Node {} [INTERNAL]: AABB min=({:.3f}, {:.3f}, {:.3f}), max=({:.3f}, {:.3f}, {:.3f}), split_axis={}, split_pos={:.3f}, left_child={}, right_child={}",
                              i,
                              node.aabb.lower_bound[0], node.aabb.lower_bound[1], node.aabb.lower_bound[2],
                              node.aabb.upper_bound[0], node.aabb.upper_bound[1], node.aabb.upper_bound[2],
                              node.split_axis, node.split_pos, node.left_child_idx, node.right_child_idx);
        }
    }
    
    // 分配mask：确保严格限制在8位内（0x01到0x80，共8个位）
    // 策略：将叶子节点分组，每组最多使用一个mask位
    // 如果叶子节点超过8个，将多余的节点合并到已有的mask组中
    
    grassland::LogInfo("[KDT] ========== Starting Mask Assignment ==========");
    
    // 第一步：收集所有叶子节点索引
    std::vector<size_t> leaf_node_indices;
    for (size_t i = 0; i < kdt_nodes_.size(); ++i) {
        if (kdt_nodes_[i].split_axis == -1) {
            leaf_node_indices.push_back(i);
        }
    }
    
    grassland::LogInfo("[KDT] Leaf node count: {}", leaf_node_indices.size());
    
    // 第二步：为叶子节点分配mask
    // mask位：0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80（共8位）
    const uint32_t MAX_MASK_BITS = 8;
    const uint32_t MASK_BITS[MAX_MASK_BITS] = {0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80};
    
    size_t num_leaves = leaf_node_indices.size();
    if (num_leaves == 0) {
        grassland::LogWarning("[KDT] KDT has no leaf nodes");
        return;
    }
    
    // 如果叶子节点数量 <= 8，每个节点分配一个独立的mask位
    // 如果叶子节点数量 > 8，将节点分组，每组共享一个mask位
    size_t mask_groups = (num_leaves <= MAX_MASK_BITS) ? num_leaves : MAX_MASK_BITS;
    grassland::LogInfo("[KDT] Mask groups: {} (leaf nodes: {}, max mask bits: {})", mask_groups, num_leaves, MAX_MASK_BITS);
    
    for (size_t leaf_idx = 0; leaf_idx < num_leaves; ++leaf_idx) {
        size_t node_idx = leaf_node_indices[leaf_idx];
        // 将叶子节点分配到mask组（循环分配）
        uint32_t mask_bit_index = leaf_idx % mask_groups;
        kdt_nodes_[node_idx].mask = MASK_BITS[mask_bit_index];
        grassland::LogInfo("[KDT] Leaf node {} -> mask group {} -> mask=0x{:02X}", node_idx, mask_bit_index, MASK_BITS[mask_bit_index]);
    }
    
    // 第三步：自底向上计算内部节点的mask（子节点mask的并集）
    // 使用后序遍历确保子节点的mask先计算
    grassland::LogInfo("[KDT] ========== Computing Internal Node Masks ==========");
    std::function<void(int)> computeInternalMask = [&](int node_idx) {
        if (node_idx < 0 || node_idx >= static_cast<int>(kdt_nodes_.size())) {
            grassland::LogWarning("[KDT] computeInternalMask: invalid node index {}", node_idx);
            return;
        }
        
        KDTNode& node = kdt_nodes_[node_idx];
        
        // 如果是叶子节点，mask已经分配好了
        if (node.split_axis == -1) {
            return;
        }
        
        // 先递归处理子节点
        if (node.left_child_idx >= 0) {
            computeInternalMask(node.left_child_idx);
        }
        if (node.right_child_idx >= 0) {
            computeInternalMask(node.right_child_idx);
        }
        
        // 计算内部节点的mask：左右子节点mask的并集
        uint32_t left_mask = (node.left_child_idx >= 0 && 
                              node.left_child_idx < static_cast<int>(kdt_nodes_.size())) 
                             ? kdt_nodes_[node.left_child_idx].mask : 0;
        uint32_t right_mask = (node.right_child_idx >= 0 && 
                               node.right_child_idx < static_cast<int>(kdt_nodes_.size())) 
                              ? kdt_nodes_[node.right_child_idx].mask : 0;
        
        // 合并mask，并确保不超过8位（0xFF）
        node.mask = (left_mask | right_mask) & 0xFF;
        
        // 安全检查：确保mask值有效
        if (node.mask == 0) {
            // 如果子节点都没有mask，使用默认值（所有位都设置）
            node.mask = 0xFF;
            grassland::LogWarning("[KDT] Node {} mask is 0, using default 0xFF", node_idx);
        }
        
        grassland::LogInfo("[KDT] Internal node {}: left_mask=0x{:02X}, right_mask=0x{:02X}, merged_mask=0x{:02X}",
                          node_idx, left_mask, right_mask, node.mask);
    };
    
    // 从根节点开始计算
    if (root_idx >= 0) {
        computeInternalMask(root_idx);
    } else {
        grassland::LogError("[KDT] Root node index invalid, cannot compute masks");
    }
    
    // 验证：确保所有mask都在8位内
    grassland::LogInfo("[KDT] ========== Validating Mask Validity ==========");
    bool has_invalid_mask = false;
    for (size_t i = 0; i < kdt_nodes_.size(); ++i) {
        if ((kdt_nodes_[i].mask & 0xFF) != kdt_nodes_[i].mask) {
            grassland::LogError("[KDT] Node {} has invalid mask: 0x{:X} (exceeds 8 bits)", i, kdt_nodes_[i].mask);
            kdt_nodes_[i].mask = 0xFF;  // 使用默认值
            has_invalid_mask = true;
        }
    }
    if (!has_invalid_mask) {
        grassland::LogInfo("[KDT] All node masks validated successfully");
    }
    
    // 转换为GPU格式
    kdt_nodes_gpu_.clear();
    kdt_nodes_gpu_.reserve(kdt_nodes_.size());
    for (const auto& node : kdt_nodes_) {
        KDTNodeGPU gpu_node;
        gpu_node.aabb_min = glm::vec3(node.aabb.lower_bound[0], node.aabb.lower_bound[1], node.aabb.lower_bound[2]);
        gpu_node.aabb_max = glm::vec3(node.aabb.upper_bound[0], node.aabb.upper_bound[1], node.aabb.upper_bound[2]);
        gpu_node.split_axis = node.split_axis;
        gpu_node.split_pos = node.split_pos;
        gpu_node.left_child_idx = node.left_child_idx;
        gpu_node.right_child_idx = node.right_child_idx;
        gpu_node.entity_start_idx = 0;  // 将在后续设置
        gpu_node.entity_count = static_cast<int32_t>(node.entity_indices.size());
        gpu_node.mask = node.mask;
        gpu_node.padding = 0;
        kdt_nodes_gpu_.push_back(gpu_node);
    }
    
    // 创建实体索引列表（用于叶子节点）
    std::vector<uint32_t> entity_index_list;
    for (size_t i = 0; i < kdt_nodes_.size(); ++i) {
        if (kdt_nodes_[i].split_axis == -1) {  // 叶子节点
            kdt_nodes_gpu_[i].entity_start_idx = static_cast<int>(entity_index_list.size());
            for (uint32_t idx : kdt_nodes_[i].entity_indices) {
                entity_index_list.push_back(idx);
            }
        }
    }
    
    // 创建GPU buffer
    size_t buffer_size = kdt_nodes_gpu_.size() * sizeof(KDTNodeGPU);
    if (!kdt_nodes_buffer_) {
        core_->CreateBuffer(buffer_size, 
                          grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                          &kdt_nodes_buffer_);
    }
    kdt_nodes_buffer_->UploadData(kdt_nodes_gpu_.data(), buffer_size);
    
    // 创建KDT信息buffer（包含节点数量）
    KDTInfo kdt_info;
    kdt_info.num_nodes = static_cast<uint32_t>(kdt_nodes_.size());
    kdt_info.padding[0] = 0;
    kdt_info.padding[1] = 0;
    kdt_info.padding[2] = 0;
    
    if (!kdt_info_buffer_) {
        core_->CreateBuffer(sizeof(KDTInfo), 
                          grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                          &kdt_info_buffer_);
    }
    kdt_info_buffer_->UploadData(&kdt_info, sizeof(KDTInfo));
    
    // 输出最终统计信息
    size_t leaf_count = std::count_if(kdt_nodes_.begin(), kdt_nodes_.end(), 
                                      [](const KDTNode& n) { return n.split_axis == -1; });
    size_t internal_count = kdt_nodes_.size() - leaf_count;
    
    grassland::LogInfo("[KDT] ========== KDT Build Completed ==========");
    grassland::LogInfo("[KDT] Total nodes: {}", kdt_nodes_.size());
    grassland::LogInfo("[KDT] Internal nodes: {}", internal_count);
    grassland::LogInfo("[KDT] Leaf nodes: {}", leaf_count);
    grassland::LogInfo("[KDT] GPU buffer size: {} bytes ({} nodes * {} bytes/node)",
                      kdt_nodes_gpu_.size() * sizeof(KDTNodeGPU),
                      kdt_nodes_gpu_.size(),
                      sizeof(KDTNodeGPU));
    grassland::LogInfo("[KDT] ==========================================");
}

// 递归构建KDT树
int Scene::BuildKDTRecursive(std::vector<std::pair<grassland::AABB, uint32_t>>& entities_with_aabb,
                              int start_idx, int end_idx, int cut_dim, int node_idx, int depth) {
    int num_entities = end_idx - start_idx;
    
    std::string indent(depth * 2, ' ');
    
    grassland::LogInfo("[KDT] {}Recursive build: node_idx={}, entity_range=[{}, {}), entity_count={}, split_axis={}",
                      indent, node_idx, start_idx, end_idx, num_entities, cut_dim);
    
    if (num_entities <= 0) {
        grassland::LogWarning("[KDT] {}Invalid entity count: {}", indent, num_entities);
        return -1;
    }
    
    if (node_idx < 0 || node_idx >= static_cast<int>(kdt_nodes_.size())) {
        grassland::LogError("[KDT] {}Node index out of range: {} (array size: {})", indent, node_idx, kdt_nodes_.size());
        return -1;
    }
    
    KDTNode& node = kdt_nodes_[node_idx];
    
    if (num_entities == 1) {
        // 叶子节点
        node.aabb = entities_with_aabb[start_idx].first;
        node.split_axis = -1;
        node.split_pos = 0.0f;
        node.left_child_idx = -1;
        node.right_child_idx = -1;
        node.entity_indices.push_back(entities_with_aabb[start_idx].second);
        
        grassland::LogInfo("[KDT] {}Created leaf node {}: entity={}, AABB min=({:.3f}, {:.3f}, {:.3f}), max=({:.3f}, {:.3f}, {:.3f})",
                          indent, node_idx, entities_with_aabb[start_idx].second,
                          node.aabb.lower_bound[0], node.aabb.lower_bound[1], node.aabb.lower_bound[2],
                          node.aabb.upper_bound[0], node.aabb.upper_bound[1], node.aabb.upper_bound[2]);
        return node_idx;
    }
    
    // 计算当前范围的AABB
    node.aabb = entities_with_aabb[start_idx].first;
    for (int i = start_idx + 1; i < end_idx; ++i) {
        node.aabb.Expand(entities_with_aabb[i].first);
    }
    
    grassland::LogInfo("[KDT] {}Computed AABB: min=({:.3f}, {:.3f}, {:.3f}), max=({:.3f}, {:.3f}, {:.3f})",
                      indent,
                      node.aabb.lower_bound[0], node.aabb.lower_bound[1], node.aabb.lower_bound[2],
                      node.aabb.upper_bound[0], node.aabb.upper_bound[1], node.aabb.upper_bound[2]);
    
    // 选择分割轴（选择AABB最长的轴）
    grassland::Vector3<float> size = node.aabb.Size();
    int best_dim = 0;
    if (size[1] > size[0]) best_dim = 1;
    if (size[2] > size[best_dim]) best_dim = 2;
    
    // 使用选定的轴进行分割
    int split_dim = best_dim;
    
    grassland::LogInfo("[KDT] {}AABB size: ({:.3f}, {:.3f}, {:.3f}), selected split axis={} (0=X, 1=Y, 2=Z)",
                      indent, size[0], size[1], size[2], split_dim);
    
    // 计算分割位置：使用中位数
    std::vector<float> centers;
    centers.reserve(num_entities);
    for (int i = start_idx; i < end_idx; ++i) {
        float center = (entities_with_aabb[i].first.lower_bound[split_dim] + 
                       entities_with_aabb[i].first.upper_bound[split_dim]) * 0.5f;
        centers.push_back(center);
    }
    
    std::nth_element(centers.begin(), centers.begin() + num_entities / 2, centers.end());
    float split_pos = centers[num_entities / 2];
    
    // 确保分割位置在AABB范围内
    float aabb_min = node.aabb.lower_bound[split_dim];
    float aabb_max = node.aabb.upper_bound[split_dim];
    float original_split_pos = split_pos;
    split_pos = std::max(aabb_min, std::min(aabb_max, split_pos));
    
    if (split_pos != original_split_pos) {
        grassland::LogWarning("[KDT] {}Split position clamped: original={:.3f}, clamped={:.3f} (AABB range: [{:.3f}, {:.3f}])",
                              indent, original_split_pos, split_pos, aabb_min, aabb_max);
    } else {
        grassland::LogInfo("[KDT] {}Split position: {:.3f} (AABB range: [{:.3f}, {:.3f}])",
                          indent, split_pos, aabb_min, aabb_max);
    }
    
    // 根据分割位置分割实体
    int mid = start_idx;
    for (int i = start_idx; i < end_idx; ++i) {
        float entity_center = (entities_with_aabb[i].first.lower_bound[split_dim] + 
                              entities_with_aabb[i].first.upper_bound[split_dim]) * 0.5f;
        if (entity_center < split_pos) {
            std::swap(entities_with_aabb[mid], entities_with_aabb[i]);
            mid++;
        }
    }
    
    // 如果所有实体都在一侧，强制分割
    if (mid == start_idx || mid == end_idx) {
        grassland::LogWarning("[KDT] {}All entities on one side, forcing split: mid={}, start={}, end={}",
                              indent, mid, start_idx, end_idx);
        mid = start_idx + num_entities / 2;
    }
    
    grassland::LogInfo("[KDT] {}Split result: left entities={}, right entities={}",
                      indent, mid - start_idx, end_idx - mid);
    
    // 设置节点属性
    node.split_axis = split_dim;
    node.split_pos = split_pos;
    
    // 递归构建左右子树
    int next_dim = (split_dim + 1) % 3;
    int next_node_idx = node_idx + 1;
    
    grassland::LogInfo("[KDT] {}Preparing to build subtrees: next_split_axis={}, next_node_idx={}",
                      indent, next_dim, next_node_idx);
    
    // 构建左子树
    int left_child_idx = BuildKDTRecursive(entities_with_aabb, start_idx, mid, next_dim, next_node_idx, depth + 1);
    node.left_child_idx = left_child_idx;
    
    if (left_child_idx < 0) {
        grassland::LogError("[KDT] {}Left subtree build failed: node index={}", indent, left_child_idx);
    } else {
        grassland::LogInfo("[KDT] {}Left subtree build completed: child node index={}", indent, left_child_idx);
    }
    
    // 计算右子树的起始节点索引：左子树使用完后就是右子树的起始位置
    // 我们需要找到左子树使用的最后一个节点索引
    int right_start_node_idx = next_node_idx;
    if (left_child_idx >= 0) {
        // 找到左子树的最大节点索引（通过递归查找）
        int left_max_idx = FindMaxNodeIndex(left_child_idx);
        right_start_node_idx = left_max_idx + 1;
        grassland::LogInfo("[KDT] {}Left subtree max node index: {}, right subtree start index: {}",
                          indent, left_max_idx, right_start_node_idx);
    } else {
        grassland::LogInfo("[KDT] {}Left subtree invalid, right subtree start index: {}", indent, right_start_node_idx);
    }
    
    // 构建右子树
    int right_child_idx = BuildKDTRecursive(entities_with_aabb, mid, end_idx, next_dim, right_start_node_idx, depth + 1);
    node.right_child_idx = right_child_idx;
    
    if (right_child_idx < 0) {
        grassland::LogError("[KDT] {}Right subtree build failed: node index={}", indent, right_child_idx);
    } else {
        grassland::LogInfo("[KDT] {}Right subtree build completed: child node index={}", indent, right_child_idx);
    }
    
    grassland::LogInfo("[KDT] {}Node {} build completed: split_axis={}, split_pos={:.3f}, left_child={}, right_child={}",
                      indent, node_idx, node.split_axis, node.split_pos, node.left_child_idx, node.right_child_idx);
    
    return node_idx;
}

// 辅助函数：找到子树中最大的节点索引
int Scene::CountNodes(int node_idx) {
    if (node_idx < 0 || node_idx >= static_cast<int>(kdt_nodes_.size())) {
        return node_idx;  // 返回当前索引或-1
    }
    
    const KDTNode& node = kdt_nodes_[node_idx];
    if (node.split_axis == -1) {
        return node_idx;  // 叶子节点，返回自身索引
    }
    
    int max_idx = node_idx;  // 当前节点索引
    if (node.left_child_idx >= 0) {
        max_idx = std::max(max_idx, CountNodes(node.left_child_idx));
    }
    if (node.right_child_idx >= 0) {
        max_idx = std::max(max_idx, CountNodes(node.right_child_idx));
    }
    return max_idx;
}

// 辅助函数：找到子树中最大的节点索引（重命名以更清晰）
int Scene::FindMaxNodeIndex(int node_idx) {
    return CountNodes(node_idx);
}

// 使用KDT分组构建TLAS
void Scene::BuildTLASWithKDT() {
    grassland::LogInfo("[TLAS] ========== Starting TLAS Build with KDT ==========");
    
    if (kdt_nodes_.empty()) {
        // 如果没有KDT，回退到原来的方法
        grassland::LogWarning("[TLAS] KDT nodes empty, using fallback method (all instances mask=0xFF)");
        std::vector<grassland::graphics::RayTracingInstance> instances;
        instances.reserve(entities_.size());
        
        for (size_t i = 0; i < entities_.size(); ++i) {
            auto& entity = entities_[i];
            if (entity->GetBLAS()) {
                glm::mat4x3 transform_3x4 = glm::mat4x3(entity->GetTransform());
                auto instance = entity->GetBLAS()->MakeInstance(
                    transform_3x4,
                    static_cast<uint32_t>(i),
                    0xFF,
                    0,
                    grassland::graphics::RAYTRACING_INSTANCE_FLAG_NONE
                );
                instances.push_back(instance);
            }
        }
        
        core_->CreateTopLevelAccelerationStructure(instances, &tlas_);
        grassland::LogInfo("[TLAS] Build completed: {} instances (fallback method)", instances.size());
        return;
    }
    
    grassland::LogInfo("[TLAS] KDT node count: {}", kdt_nodes_.size());
    
    // 收集所有实例，为每个实例分配对应的mask
    std::vector<grassland::graphics::RayTracingInstance> instances;
    instances.reserve(entities_.size());
    
    // 为每个实体找到它所属的所有叶子节点，并收集mask
    // 注意：一个实体可能只属于一个叶子节点（KDT的特性）
    std::vector<uint32_t> entity_masks(entities_.size(), 0);
    
    grassland::LogInfo("[TLAS] ========== Assigning Entity Masks ==========");
    for (size_t i = 0; i < kdt_nodes_.size(); ++i) {
        if (kdt_nodes_[i].split_axis == -1) {  // 叶子节点
            uint32_t mask = kdt_nodes_[i].mask;
            // 确保mask在8位内
            mask &= 0xFF;
            
            grassland::LogInfo("[TLAS] Leaf node {}: mask=0x{:02X}, entity_count={}",
                              i, mask, kdt_nodes_[i].entity_indices.size());
            
            for (uint32_t entity_idx : kdt_nodes_[i].entity_indices) {
                if (entity_idx < entity_masks.size()) {
                    uint32_t old_mask = entity_masks[entity_idx];
                    // 合并mask（使用OR操作）
                    entity_masks[entity_idx] |= mask;
                    // 确保结果也在8位内
                    entity_masks[entity_idx] &= 0xFF;
                    
                    if (old_mask != entity_masks[entity_idx]) {
                        grassland::LogInfo("[TLAS]   Entity {}: mask 0x{:02X} -> 0x{:02X} (merged)",
                                          entity_idx, old_mask, entity_masks[entity_idx]);
                    }
                } else {
                    grassland::LogError("[TLAS]   Entity index {} out of range (max: {})", entity_idx, entity_masks.size() - 1);
                }
            }
        }
    }
    
    // 创建实例
    grassland::LogInfo("[TLAS] ========== Creating TLAS Instances ==========");
    for (size_t i = 0; i < entities_.size(); ++i) {
        auto& entity = entities_[i];
        if (entity->GetBLAS()) {
            glm::mat4x3 transform_3x4 = glm::mat4x3(entity->GetTransform());
            uint32_t mask = (i < entity_masks.size()) ? entity_masks[i] : 0xFF;
            
            // 确保mask在8位内
            mask &= 0xFF;
            
            // 如果mask为0，使用默认值（所有位都设置，表示匹配所有组）
            if (mask == 0) {
                grassland::LogWarning("[TLAS] Entity {} mask is 0, using default 0xFF", i);
                mask = 0xFF;
            }
            
            grassland::LogInfo("[TLAS] Entity {}: mask=0x{:02X}", i, mask);
            
            auto instance = entity->GetBLAS()->MakeInstance(
                transform_3x4,
                static_cast<uint32_t>(i),
                mask,
                0,
                grassland::graphics::RAYTRACING_INSTANCE_FLAG_NONE
            );
            instances.push_back(instance);
        } else {
            grassland::LogWarning("[TLAS] Entity {} has no BLAS, skipping", i);
        }
    }
    
    // 构建TLAS
    grassland::LogInfo("[TLAS] Starting TLAS build, instance count: {}", instances.size());
    core_->CreateTopLevelAccelerationStructure(instances, &tlas_);
    grassland::LogInfo("[TLAS] TLAS build completed: {} instances", instances.size());
    grassland::LogInfo("[TLAS] ============================================");
}

// Debug: 输出所有KDT节点的AABB信息
void Scene::DebugPrintKDTNodes() const {
    grassland::LogInfo("[KDT DEBUG] ========== All KDT Nodes AABB Info ==========");
    for (size_t i = 0; i < kdt_nodes_.size(); ++i) {
        const KDTNode& node = kdt_nodes_[i];
        if (node.split_axis == -1) {
            grassland::LogInfo("[KDT DEBUG] Node {} [LEAF]: AABB min=({:.3f}, {:.3f}, {:.3f}), max=({:.3f}, {:.3f}, {:.3f}), "
                              "mask=0x{:02X}, entities={}",
                              i,
                              node.aabb.lower_bound[0], node.aabb.lower_bound[1], node.aabb.lower_bound[2],
                              node.aabb.upper_bound[0], node.aabb.upper_bound[1], node.aabb.upper_bound[2],
                              node.mask, node.entity_indices.size());
        } else {
            grassland::LogInfo("[KDT DEBUG] Node {} [INTERNAL]: AABB min=({:.3f}, {:.3f}, {:.3f}), max=({:.3f}, {:.3f}, {:.3f}), "
                              "split_axis={}, split_pos={:.3f}, left={}, right={}, mask=0x{:02X}",
                              i,
                              node.aabb.lower_bound[0], node.aabb.lower_bound[1], node.aabb.lower_bound[2],
                              node.aabb.upper_bound[0], node.aabb.upper_bound[1], node.aabb.upper_bound[2],
                              node.split_axis, node.split_pos, node.left_child_idx, node.right_child_idx, node.mask);
        }
    }
    grassland::LogInfo("[KDT DEBUG] =============================================");
}

// Debug: 测试光线与哪些AABB相交（使用与shader相同的算法）
std::vector<Scene::KDTIntersectionInfo> Scene::DebugTestRayAABBIntersection(const glm::vec3& rayOrigin, const glm::vec3& rayDir, float tMin, float tMax) const {
    std::vector<KDTIntersectionInfo> intersections;
    
    for (size_t i = 0; i < kdt_nodes_.size(); ++i) {
        const KDTNode& node = kdt_nodes_[i];
        
        // 使用与shader相同的RayAABBIntersect算法（改进版本，考虑符号和精度）
        glm::vec3 invDir;
        float epsilon = 1e-6f;
        invDir.x = std::abs(rayDir.x) > epsilon ? 1.0f / rayDir.x : (rayDir.x >= 0.0f ? 1e30f : -1e30f);
        invDir.y = std::abs(rayDir.y) > epsilon ? 1.0f / rayDir.y : (rayDir.y >= 0.0f ? 1e30f : -1e30f);
        invDir.z = std::abs(rayDir.z) > epsilon ? 1.0f / rayDir.z : (rayDir.z >= 0.0f ? 1e30f : -1e30f);
        
        glm::vec3 aabbMin(node.aabb.lower_bound[0], node.aabb.lower_bound[1], node.aabb.lower_bound[2]);
        glm::vec3 aabbMax(node.aabb.upper_bound[0], node.aabb.upper_bound[1], node.aabb.upper_bound[2]);
        
        glm::vec3 t0 = (aabbMin - rayOrigin) * invDir;
        glm::vec3 t1 = (aabbMax - rayOrigin) * invDir;
        
        glm::vec3 tNear = glm::min(t0, t1);
        glm::vec3 tFar = glm::max(t0, t1);
        
        float tNearMax = std::max(std::max(tNear.x, tNear.y), tNear.z);
        float tFarMin = std::min(std::min(tFar.x, tFar.y), tFar.z);
        
        // 使用与shader相同的检查逻辑（改进版本）
        if (tNearMax > tFarMin + epsilon) {
            continue;  // 不相交
        }
        
        // 检查相交点是否在有效范围内
        if (tFarMin < tMin - epsilon || tNearMax > tMax + epsilon) {
            continue;  // 相交点不在有效范围内
        }
        
        // 计算相交的t值
        float tHit = std::max(tNearMax, tMin);
        if (tHit > tMax + epsilon) {
            continue;  // t值超出范围
        }
        
        // 相交，添加到结果列表
        KDTIntersectionInfo info;
        info.node_idx = static_cast<int>(i);
        info.is_leaf = (node.split_axis == -1);
        info.t_hit = tHit;
        info.aabb_min = aabbMin;
        info.aabb_max = aabbMax;
        info.split_axis = node.split_axis;
        info.split_pos = node.split_pos;
        info.mask = node.mask;
        info.entity_count = static_cast<int>(node.entity_indices.size());
        intersections.push_back(info);
    }
    
    // 按t_hit排序，从近到远
    std::sort(intersections.begin(), intersections.end(), 
              [](const KDTIntersectionInfo& a, const KDTIntersectionInfo& b) {
                  return a.t_hit < b.t_hit;
              });
    
    return intersections;
}

