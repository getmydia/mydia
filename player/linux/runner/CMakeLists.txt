cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

# Flutter 3.50's libflutter_linux_gtk.so exports libunwind's _Unwind_* symbols
# (flutter/flutter#196402). The runner listed it ahead of libgcc_s, so the
# dynamic linker bound every C++ throw to the engine's unwinder, which cannot
# find libstdc++ catch handlers: a plugin catching its own exception aborted
# the app instead (flutter_secure_storage_linux with no keyring died at launch
# with "terminate called after throwing an instance of 'LibsecretError'"), and
# so does a Rust panic in the p2p library. Linking libgcc_s first puts its
# unwinder ahead in symbol lookup. Remove this once .fvmrc pins a Flutter that
# includes flutter/flutter#196451, which hides those symbols in the engine.
target_link_options(${BINARY_NAME} PRIVATE
  "LINKER:--push-state,--no-as-needed,-lgcc_s,--pop-state")

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
