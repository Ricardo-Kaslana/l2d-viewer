cmake_minimum_required(VERSION 3.22)
project(native_window_jni LANGUAGES CXX)

add_library(native_window SHARED native_window_jni.cpp)
target_link_libraries(native_window android log)
