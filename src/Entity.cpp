#include "Entity.h"

// 构造函数：初始化实体对象
Entity::Entity(const std::string& obj_file_path, 
               const Material& material,
               const glm::mat4& transform,
               const std::string& texture_path,
               const std::string& normal_map_path,
               const std::string& height_map_path)
    : material_(material)
    , transform_(transform)
    , texture_path_(texture_path)
    , normal_map_path_(normal_map_path)
    , height_map_path_(height_map_path)
    , mesh_loaded_(false) {
    
    // 立即尝试加载网格
    LoadMesh(obj_file_path);
}

// 析构函数：按顺序释放GPU资源
Entity::~Entity() {
    blas_.reset();
    normal_buffer_.reset();
    index_buffer_.reset();
    vertex_buffer_.reset();
    texture_.reset();
    normal_map_.reset();
    height_map_.reset();
}

// 从OBJ文件加载网格数据
// obj_file_path: OBJ文件路径（相对路径）
// 返回：成功返回true，失败返回false
bool Entity::LoadMesh(const std::string& obj_file_path) {
    // 查找资源文件的完整路径
    std::string full_path = grassland::FindAssetFile(obj_file_path);
    
    // 尝试加载OBJ文件
    if (mesh_.LoadObjFile(full_path) != 0) {
        grassland::LogError("Failed to load mesh from: {}", obj_file_path);
        mesh_loaded_ = false;
        return false;
    }

    // 记录成功加载的信息
    grassland::LogInfo("Successfully loaded mesh: {} ({} vertices, {} indices)", 
                       obj_file_path, mesh_.NumVertices(), mesh_.NumIndices());
    
    mesh_loaded_ = true;
    return true;
}

// 构建底层加速结构（BLAS）
// core: 图形核心对象指针
// 功能：创建顶点、索引、法线缓冲区，并构建用于光线追踪的BLAS
void Entity::BuildBLAS(grassland::graphics::Core* core) {
    // 检查网格是否已加载
    if (!mesh_loaded_) {
        grassland::LogError("Cannot build BLAS: mesh not loaded");
        return;
    }

    // 创建顶点缓冲区
    size_t vertex_buffer_size = mesh_.NumVertices() * sizeof(glm::vec3);
    core->CreateBuffer(vertex_buffer_size, 
                      grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                      &vertex_buffer_);
    vertex_buffer_->UploadData(mesh_.Positions(), vertex_buffer_size);

    // 创建法线缓冲区（仅当网格有法线数据时）
    if (mesh_.Normals()) {
        size_t normal_buffer_size = mesh_.NumVertices() * sizeof(glm::vec3);
        core->CreateBuffer(normal_buffer_size, 
                          grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                          &normal_buffer_);
        normal_buffer_->UploadData(mesh_.Normals(), normal_buffer_size);
        grassland::LogInfo("Created normal buffer with {} normals", mesh_.NumVertices());
    } else {
        grassland::LogWarning("Mesh has no normals - will generate defaults or use geometric normals");
    }

    // 创建索引缓冲区
    size_t index_buffer_size = mesh_.NumIndices() * sizeof(uint32_t);
    core->CreateBuffer(index_buffer_size, 
                      grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                      &index_buffer_);
    index_buffer_->UploadData(mesh_.Indices(), index_buffer_size);

    // 构建BLAS（底层加速结构，用于光线追踪）
    core->CreateBottomLevelAccelerationStructure(
        vertex_buffer_.get(), 
        index_buffer_.get(), 
        sizeof(glm::vec3), 
        &blas_);

    grassland::LogInfo("Built BLAS for entity ({} vertices, {} indices)", 
                       mesh_.NumVertices(), mesh_.NumIndices());
    
    // 如果提供了纹理路径，则加载纹理
    if (!texture_path_.empty()) {
        LoadTexture(core, texture_path_);
    }
    
    // 如果提供了法线贴图路径，则加载法线贴图
    if (!normal_map_path_.empty()) {
        LoadNormalMap(core, normal_map_path_);
    }
    
    // 如果提供了高度贴图路径，则加载高度贴图
    if (!height_map_path_.empty()) {
        LoadHeightMap(core, height_map_path_);
    }
}

// 从文件加载纹理
// core: 图形核心对象指针
// texture_path: 纹理文件路径（相对路径）
// 返回：成功返回true，失败返回false
bool Entity::LoadTexture(grassland::graphics::Core* core, const std::string& texture_path) {
    // 检查路径是否为空
    if (texture_path.empty()) {
        grassland::LogWarning("Empty texture path provided");
        return false;
    }
    
    // 查找资源文件的完整路径
    std::string full_path = grassland::FindAssetFile(texture_path);
    
    // 使用框架的LoadImageFromFile函数加载图像
    if (grassland::graphics::LoadImageFromFile(core, full_path, &texture_) != 0) {
        grassland::LogError("Failed to load texture from: {}", texture_path);
        return false;
    }
    
    // 记录成功加载的信息
    grassland::LogInfo("Successfully loaded texture: {} ({}x{})", 
                       texture_path, 
                       texture_->Extent().width, 
                       texture_->Extent().height);
    return true;
}

// 从文件加载法线贴图
// core: 图形核心对象指针
// normal_map_path: 法线贴图文件路径（相对路径）
// 返回：成功返回true，失败返回false
bool Entity::LoadNormalMap(grassland::graphics::Core* core, const std::string& normal_map_path) {
    // 检查路径是否为空
    if (normal_map_path.empty()) {
        grassland::LogWarning("Empty normal map path provided");
        return false;
    }
    
    // 查找资源文件的完整路径
    std::string full_path = grassland::FindAssetFile(normal_map_path);
    
    // 使用框架的LoadImageFromFile函数加载图像
    if (grassland::graphics::LoadImageFromFile(core, full_path, &normal_map_) != 0) {
        grassland::LogError("Failed to load normal map from: {}", normal_map_path);
        return false;
    }
    
    // 记录成功加载的信息
    grassland::LogInfo("Successfully loaded normal map: {} ({}x{})", 
                       normal_map_path, 
                       normal_map_->Extent().width, 
                       normal_map_->Extent().height);
    return true;
}

// 从文件加载高度贴图
// core: 图形核心对象指针
// height_map_path: 高度贴图文件路径（相对路径）
// 返回：成功返回true，失败返回false
bool Entity::LoadHeightMap(grassland::graphics::Core* core, const std::string& height_map_path) {
    // 检查路径是否为空
    if (height_map_path.empty()) {
        grassland::LogWarning("Empty height map path provided");
        return false;
    }
    
    // 查找资源文件的完整路径
    std::string full_path = grassland::FindAssetFile(height_map_path);
    
    // 使用框架的LoadImageFromFile函数加载图像
    if (grassland::graphics::LoadImageFromFile(core, full_path, &height_map_) != 0) {
        grassland::LogError("Failed to load height map from: {}", height_map_path);
        return false;
    }
    
    // 记录成功加载的信息
    grassland::LogInfo("Successfully loaded height map: {} ({}x{})", 
                       height_map_path, 
                       height_map_->Extent().width, 
                       height_map_->Extent().height);
    return true;
}
