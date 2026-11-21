# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "mydia_player_p2p")
project(${PROJECT_NAME} LANGUAGES CXX)

# MYDIA_PLAYER_P2P_PREBUILT names an already built libmydia_player_p2p.so to
# bundle instead of running cargokit. The Nix CI's player-linux check
# (nix/ci/player.nix) sets it to a crane-built library: cargokit's build tool
# runs `dart pub get` for its own dependencies, none of which are in the
# player's lockfile, so it cannot start in the offline sandbox, let alone
# reach cargo. Unset, which is every other build, nothing changes.
if(DEFINED ENV{MYDIA_PLAYER_P2P_PREBUILT})
  set(mydia_player_p2p_prebuilt "$ENV{MYDIA_PLAYER_P2P_PREBUILT}")
  get_filename_component(mydia_player_p2p_prebuilt_name "${mydia_player_p2p_prebuilt}" NAME)
  if(NOT mydia_player_p2p_prebuilt_name STREQUAL "libmydia_player_p2p.so"
     OR NOT EXISTS "${mydia_player_p2p_prebuilt}")
    # flutter_rust_bridge opens the library by this exact name from bundle/lib.
    message(FATAL_ERROR "MYDIA_PLAYER_P2P_PREBUILT must name an existing libmydia_player_p2p.so, got '${mydia_player_p2p_prebuilt}'")
  endif()
  set(mydia_player_p2p_bundled_libraries
    "${mydia_player_p2p_prebuilt}"
    PARENT_SCOPE
  )
  return()
endif()

include("../cargokit/cmake/cargokit.cmake")
apply_cargokit(${PROJECT_NAME} ../../rust/mydia_player_p2p mydia_player_p2p "")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(mydia_player_p2p_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
