cmake_minimum_required(VERSION 3.20)

# The SSH bridge on the development host, for the integration tests against a
# throwaway sshd (tests/run_integration.sh). The shipping build is
# scripts/build-ssh-xcframework.sh, which compiles the same sources for iOS,
# the Simulator and Mac Catalyst against the OpenSSL in FreeRDP.xcframework.

project(mremote_ssh_bridge VERSION 0.1.0 LANGUAGES C)

include(CTest)
find_package(Threads REQUIRED)
find_package(OpenSSL REQUIRED)

set(MR_LIBSSH2_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../.build/ssh/src/libssh2"
    CACHE PATH "The pinned libssh2 checkout (scripts/build-ssh-xcframework.sh fetches it)")
set(MR_SSH_SANITIZER "none" CACHE STRING "Sanitizer: none, address, undefined, or thread")
set_property(CACHE MR_SSH_SANITIZER PROPERTY STRINGS none address undefined thread)

if(NOT EXISTS "${MR_LIBSSH2_SOURCE_DIR}/src/Makefile.inc")
    message(FATAL_ERROR "libssh2 not found at ${MR_LIBSSH2_SOURCE_DIR}; run scripts/build-ssh-xcframework.sh --fetch-only")
endif()

# The same source list and flags as the xcframework build.
include(${CMAKE_CURRENT_SOURCE_DIR}/libssh2-sources.cmake)

add_library(mremote_libssh2 STATIC ${MR_LIBSSH2_SOURCES})
target_include_directories(mremote_libssh2
    PUBLIC "${MR_LIBSSH2_SOURCE_DIR}/include"
    PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/config")
target_compile_definitions(mremote_libssh2 PRIVATE ${MR_LIBSSH2_DEFINITIONS})
target_link_libraries(mremote_libssh2 PUBLIC OpenSSL::Crypto)

add_library(mremote_ssh_bridge STATIC src/ssh_bridge.c src/ssh_forward.c)
target_compile_features(mremote_ssh_bridge PUBLIC c_std_11)
target_include_directories(mremote_ssh_bridge PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(mremote_ssh_bridge PUBLIC mremote_libssh2 Threads::Threads)
target_compile_options(mremote_ssh_bridge PRIVATE -Wall -Wextra -Wpedantic -Werror)

if(NOT MR_SSH_SANITIZER STREQUAL "none")
    foreach(_target mremote_libssh2 mremote_ssh_bridge)
        target_compile_options(${_target} PUBLIC -fsanitize=${MR_SSH_SANITIZER} -fno-omit-frame-pointer -g)
        target_link_options(${_target} PUBLIC -fsanitize=${MR_SSH_SANITIZER})
    endforeach()
endif()

if(BUILD_TESTING)
    add_executable(ssh_bridge_tests tests/ssh_bridge_tests.c)
    target_link_libraries(ssh_bridge_tests PRIVATE mremote_ssh_bridge)
    target_compile_options(ssh_bridge_tests PRIVATE -Wall -Wextra -Werror)
    add_test(NAME ssh_bridge_integration
        COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/tests/run_integration.sh" $<TARGET_FILE:ssh_bridge_tests>)
endif()
