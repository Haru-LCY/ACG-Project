#pragma once
#include "long_march.h"

// Film类：用于累积光线追踪样本，实现渐进式渲染
// 当相机静止时，通过累积多帧样本来提高图像质量
// Film class for accumulating ray tracing samples over time
// Used for progressive rendering when camera is stationary
class Film {
public:
    // 构造函数：创建Film对象
    // core: 图形核心对象指针
    // width: 图像宽度（像素）
    // height: 图像高度（像素）
    Film(grassland::graphics::Core* core, int width, int height);
    
    // 析构函数：释放资源
    ~Film();

    // 重置累积缓冲区（相机移动或场景变化时调用）
    void Reset();

    // 获取累积颜色图像（用于显示）
    grassland::graphics::Image* GetAccumulatedColorImage() const { return accumulated_color_image_.get(); }
    
    // 获取样本计数图像（用于shader）
    grassland::graphics::Image* GetAccumulatedSamplesImage() const { return accumulated_samples_image_.get(); }
    
    // 获取最终输出图像（平均后的结果）
    grassland::graphics::Image* GetOutputImage() const { return output_image_.get(); }

    // 获取当前累积的样本数量
    int GetSampleCount() const { return sample_count_; }

    // 递增样本计数（每帧调用一次）
    void IncrementSampleCount() { sample_count_++; }

    // 将累积数据转换为最终输出图像（除以样本数量得到平均值）
    // 注意：此函数在CPU端执行，可能较慢，理想情况下应在GPU端实现
    void DevelopToOutput();

    // 调整Film尺寸（窗口大小改变时调用）
    // width: 新宽度
    // height: 新高度
    void Resize(int width, int height);

    // 获取图像宽度
    int GetWidth() const { return width_; }
    // 获取图像高度
    int GetHeight() const { return height_; }

private:
    grassland::graphics::Core* core_;          // 图形核心对象指针
    int width_;                                 // 图像宽度
    int height_;                                // 图像高度
    int sample_count_;                          // 累积的样本数量

    // 累积颜色图像（所有样本的总和，RGBA32F格式）
    std::unique_ptr<grassland::graphics::Image> accumulated_color_image_;
    
    // 累积样本计数图像（每像素的样本数，R32_SINT格式）
    std::unique_ptr<grassland::graphics::Image> accumulated_samples_image_;
    
    // 最终输出图像（accumulated_color / accumulated_samples，RGBA32F格式）
    std::unique_ptr<grassland::graphics::Image> output_image_;

    // 创建所有图像缓冲区（内部辅助函数）
    void CreateImages();
};

