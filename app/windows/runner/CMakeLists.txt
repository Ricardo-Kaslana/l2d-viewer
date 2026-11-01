cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "../texture_handler.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# PluginRegistrar / PluginRegistrarManager live in plugin_registrar.cc
# (part of flutter_wrapper_plugin, which is not linked into the runner).
# Compile that single source directly so flutter_window.cpp can resolve
# flutter::PluginRegistrarManager without duplicating the core wrapper
# objects from flutter_wrapper_app.
#
# The Flutter tool normally generates the C++ wrapper under
# flutter/ephemeral, but on a clean checkout CMake configures before
# flutter_assemble runs. Use the Flutter SDK's engine wrapper as the
# configure-time source, and let the normal Flutter build generate the
# ephemeral runtime files later.
if (NOT FLUTTER_ROOT AND DEFINED ENV{FLUTTER_ROOT})
  set(FLUTTER_ROOT "$ENV{FLUTTER_ROOT}")
endif()
if (NOT FLUTTER_ROOT)
  find_program(FLUTTER_EXECUTABLE NAMES flutter flutter.bat)
  if (FLUTTER_EXECUTABLE)
    get_filename_component(_flutter_bin "${FLUTTER_EXECUTABLE}" DIRECTORY)
    get_filename_component(FLUTTER_ROOT "${_flutter_bin}" DIRECTORY)
  endif()
endif()
if (NOT FLUTTER_TARGET_PLATFORM)
  set(FLUTTER_TARGET_PLATFORM "windows-x64")
endif()
set(_flutter_wrapper_root
  "${FLUTTER_ROOT}/bin/cache/artifacts/engine/${FLUTTER_TARGET_PLATFORM}/cpp_client_wrapper")
if (EXISTS "${_flutter_wrapper_root}/plugin_registrar.cc")
  target_sources(${BINARY_NAME} PRIVATE
    "${_flutter_wrapper_root}/plugin_registrar.cc"
  )
  target_include_directories(${BINARY_NAME} PRIVATE
    "${_flutter_wrapper_root}/include"
  )
else()
  message(FATAL_ERROR
    "Flutter C++ wrapper not found at ${_flutter_wrapper_root}. "
    "Run `flutter precache --windows` and retry.")
endif()

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "d3d11.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "dxgi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Build the Rust FRB cdylib (mocari_host.dll) and copy it to the output
# directory so RustLib.init() can find it at runtime.
#
# The Rust project root is the repository root (where Cargo.toml lives).
# CMAKE_SOURCE_DIR = app/windows/;  ../..  from there = repo root.
#
# Flutter Windows uses a multi-config generator (Debug;Profile;Release), so
# the cargo profile must be selected per $<CONFIG>: Debug keeps the default
# `dev` profile, while Profile and Release ship the optimized `release` DLL.
set(RUST_PROJECT_ROOT "${CMAKE_SOURCE_DIR}/../..")
set(RUST_CARGO_PROFILE "$<IF:$<CONFIG:Debug>,dev,release>")
set(RUST_TARGET_SUBDIR "$<IF:$<CONFIG:Debug>,debug,release>")
set(RUST_DLL "${RUST_PROJECT_ROOT}/target/${RUST_TARGET_SUBDIR}/mocari_host.dll")

add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND cargo build -p mocari_host --profile "${RUST_CARGO_PROFILE}"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${RUST_DLL}"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/"
  WORKING_DIRECTORY "${RUST_PROJECT_ROOT}"
  COMMENT "Building and copying mocari_host.dll (cargo profile per config)"
)
