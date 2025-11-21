# 明确列出源文件，避免包含不需要的文件
set(DEMO_SOURCES
    main.cpp
    app.cpp
    Scene.cpp
    Film.cpp
    Entity.cpp
    app.h
    Scene.h
    Film.h
    Entity.h
    Material.h
    stb_image_write.h
)

add_executable(ShortMarchDemo ${DEMO_SOURCES})

target_include_directories(ShortMarchDemo PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/shaders)
target_compile_definitions(ShortMarchDemo PUBLIC SHADER_DIR="${CMAKE_CURRENT_SOURCE_DIR}/shaders/")

target_link_libraries(ShortMarchDemo LongMarch)

PACK_SHADER_CODE(ShortMarchDemo)

