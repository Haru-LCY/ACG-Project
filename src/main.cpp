#include "app.h"

// 程序入口点
// 功能：创建应用程序实例，运行主循环，处理窗口事件
int main() {
  // 只创建一个应用程序实例以避免ImGui冲突
  // 如果偏好Vulkan，可以将BACKEND_API_D3D12改为BACKEND_API_VULKAN
  Application app{grassland::graphics::BACKEND_API_D3D12};

  // 初始化应用程序
  app.OnInit();

  // 主循环：持续运行直到应用程序关闭
  while (app.IsAlive()) {
    // 更新应用程序状态（处理输入、更新相机等）
    app.OnUpdate();
    // 更新后再次检查是否存活（可能在更新过程中关闭）
    if (app.IsAlive()) {
      // 渲染一帧
      app.OnRender();
    }
    // 处理GLFW窗口事件（鼠标、键盘等）
    glfwPollEvents();
  }

  // 清理资源
  app.OnClose();

  return 0;
}
