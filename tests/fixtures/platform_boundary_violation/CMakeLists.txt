cmake_minimum_required(VERSION 3.20)

project(platform_boundary_violation LANGUAGES C)

add_library(ejs_apple_platform STATIC platform/dummy.c)
target_link_libraries(ejs_apple_platform PRIVATE
  ejs_core
  ejs_fs_apple
)
