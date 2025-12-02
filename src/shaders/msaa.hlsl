// ==================== MSAA Module ====================
// 多重采样抗锯齿 (MSAA) 模块
// 提供标准 MSAA 采样模式和子像素抖动生成函数
// 用于光线追踪中的抗锯齿

#ifndef MSAA_HLSL
#define MSAA_HLSL

// ==================== MSAA 模式定义 ====================
// 这些值需要与 C++ 端的定义匹配
#define MSAA_MODE_OFF      0   // 关闭 MSAA（单采样）
#define MSAA_MODE_2X       1   // 2x MSAA
#define MSAA_MODE_4X       2   // 4x MSAA  
#define MSAA_MODE_8X       3   // 8x MSAA
#define MSAA_MODE_RANDOM   4   // 随机抖动（原有模式）

// ==================== 标准 MSAA 采样位置 ====================
// 采样位置在 [-0.5, 0.5] 范围内，相对于像素中心
// 这些是 D3D11/D3D12 标准 MSAA 采样位置

// 2x MSAA 采样位置
static const float2 MSAA_2X_SAMPLES[2] = {
    float2(-0.25f,  0.25f),
    float2( 0.25f, -0.25f)
};

// 4x MSAA 采样位置 (标准 D3D 旋转网格模式)
static const float2 MSAA_4X_SAMPLES[4] = {
    float2(-0.125f, -0.375f),
    float2( 0.375f, -0.125f),
    float2(-0.375f,  0.125f),
    float2( 0.125f,  0.375f)
};

// 8x MSAA 采样位置
static const float2 MSAA_8X_SAMPLES[8] = {
    float2( 0.0625f, -0.1875f),
    float2(-0.0625f,  0.1875f),
    float2( 0.3125f,  0.0625f),
    float2(-0.1875f, -0.3125f),
    float2(-0.3125f,  0.3125f),
    float2(-0.4375f, -0.0625f),
    float2( 0.1875f,  0.4375f),
    float2( 0.4375f, -0.4375f)
};

// ==================== MSAA 采样函数 ====================

// 获取指定 MSAA 模式的采样数量
int GetMSAASampleCount(int msaa_mode) {
    switch (msaa_mode) {
        case MSAA_MODE_2X:     return 2;
        case MSAA_MODE_4X:     return 4;
        case MSAA_MODE_8X:     return 8;
        case MSAA_MODE_OFF:    return 1;
        case MSAA_MODE_RANDOM: return 1;  // 随机模式每次返回1，由外部控制采样次数
        default:               return 1;
    }
}

// 获取 MSAA 采样位置
// msaa_mode: MSAA 模式
// sample_idx: 采样索引 (0 到 sample_count-1)
// seed: 随机种子 (仅用于 MSAA_MODE_RANDOM)
// 返回: 子像素偏移量，范围 [-0.5, 0.5]
float2 GetMSAASampleOffset(int msaa_mode, int sample_idx, inout uint seed) {
    switch (msaa_mode) {
        case MSAA_MODE_OFF:
            // 无 MSAA，返回像素中心 (0, 0)
            return float2(0.0f, 0.0f);
            
        case MSAA_MODE_2X:
            return MSAA_2X_SAMPLES[sample_idx % 2];
            
        case MSAA_MODE_4X:
            return MSAA_4X_SAMPLES[sample_idx % 4];
            
        case MSAA_MODE_8X:
            return MSAA_8X_SAMPLES[sample_idx % 8];
            
        case MSAA_MODE_RANDOM:
        default:
            // 随机抖动模式 - 需要包含 rng.hlsl 中的 Rand01 函数
            // 这里假设外部已包含 rng.hlsl
            {
                seed = PCGHash(seed);
                float jx = Rand01(seed) - 0.5f;
                seed = PCGHash(seed);
                float jy = Rand01(seed) - 0.5f;
                return float2(jx, jy);
            }
    }
}

// ==================== 分层采样 (Stratified Sampling) ====================
// 用于更均匀的随机采样分布

// 获取分层采样偏移
// 将像素划分为 sqrt(n) x sqrt(n) 的网格，在每个格子内随机采样
// sample_idx: 当前采样索引
// total_samples: 总采样数（应为完全平方数：1, 4, 9, 16...）
// seed: 随机种子
float2 GetStratifiedSampleOffset(int sample_idx, int total_samples, inout uint seed) {
    // 计算网格维度
    int grid_size = (int)ceil(sqrt((float)total_samples));
    
    // 计算当前采样所在的网格单元
    int cell_x = sample_idx % grid_size;
    int cell_y = sample_idx / grid_size;
    
    // 在单元内随机采样
    seed = PCGHash(seed);
    float rx = Rand01(seed);
    seed = PCGHash(seed);
    float ry = Rand01(seed);
    
    // 计算最终偏移量 (映射到 [-0.5, 0.5])
    float cell_size = 1.0f / (float)grid_size;
    float offset_x = ((float)cell_x + rx) * cell_size - 0.5f;
    float offset_y = ((float)cell_y + ry) * cell_size - 0.5f;
    
    return float2(offset_x, offset_y);
}

// ==================== 蓝噪声采样 (Blue Noise Sampling) ====================
// 基于 R2 低差异序列的采样，提供更好的采样分布

// R2 序列常数 (基于黄金比例)
static const float R2_ALPHA1 = 0.7548776662466927f;  // 1 / phi^2
static const float R2_ALPHA2 = 0.5698402909980532f;  // 1 / phi

// 获取 R2 序列采样偏移
// sample_idx: 采样索引
// 返回: 低差异序列采样位置 (范围 [-0.5, 0.5])
float2 GetR2SampleOffset(int sample_idx) {
    float x = frac(0.5f + R2_ALPHA1 * (float)sample_idx);
    float y = frac(0.5f + R2_ALPHA2 * (float)sample_idx);
    return float2(x - 0.5f, y - 0.5f);
}

// ==================== Halton 序列采样 ====================
// 另一种常用的低差异序列

float HaltonSequence(int index, int base) {
    float result = 0.0f;
    float f = 1.0f;
    int i = index;
    while (i > 0) {
        f = f / (float)base;
        result = result + f * (float)(i % base);
        i = i / base;
    }
    return result;
}

// 获取 Halton 序列采样偏移
float2 GetHaltonSampleOffset(int sample_idx) {
    // 使用基数 2 和 3
    float x = HaltonSequence(sample_idx + 1, 2);  // +1 避免 (0,0)
    float y = HaltonSequence(sample_idx + 1, 3);
    return float2(x - 0.5f, y - 0.5f);
}

// ==================== 高级 MSAA 采样函数 ====================

// 组合模式：标准 MSAA + 时间累积
// 当帧累积时，在 MSAA 模式基础上添加时间偏移
float2 GetTemporalMSAASampleOffset(
    int msaa_mode, 
    int sample_idx, 
    int frame_idx,      // 当前帧索引（用于时间累积）
    inout uint seed
) {
    // 获取基础 MSAA 偏移
    float2 base_offset = GetMSAASampleOffset(msaa_mode, sample_idx, seed);
    
    // 如果是时间累积模式，添加帧间偏移
    if (frame_idx > 0) {
        // 使用 R2 序列为不同帧添加子像素偏移
        float2 temporal_offset = GetR2SampleOffset(frame_idx) * 0.5f;  // 缩小偏移范围
        base_offset += temporal_offset;
        
        // 确保偏移在有效范围内
        base_offset = clamp(base_offset, float2(-0.5f, -0.5f), float2(0.5f, 0.5f));
    }
    
    return base_offset;
}

// ==================== 实用工具函数 ====================

// 计算采样权重（用于加权平均）
// 某些 MSAA 模式可能需要非均匀权重
float GetMSAASampleWeight(int msaa_mode, int sample_idx) {
    // 标准 MSAA 使用均匀权重
    // 可以扩展为支持自定义权重
    return 1.0f;
}

// 检查是否应该使用 MSAA
bool IsMSAAEnabled(int msaa_mode) {
    return msaa_mode != MSAA_MODE_OFF;
}

#endif // MSAA_HLSL
