cmake_minimum_required(VERSION 3.20)

project(mremote_rdp_bridge VERSION 0.1.0 LANGUAGES C)

include(CTest)
find_package(Threads REQUIRED)

option(MR_BRIDGE_WARNINGS_AS_ERRORS "Treat bridge warnings as errors" ON)
option(MR_BRIDGE_CERTIFICATE_TESTS "Build PEM-to-DER parser tests with host OpenSSL" OFF)
set(MR_BRIDGE_SANITIZER "none" CACHE STRING "Sanitizer: none, address, undefined, or thread")
set_property(CACHE MR_BRIDGE_SANITIZER PROPERTY STRINGS none address undefined thread)
set(MR_BRIDGE_BACKEND "unavailable" CACHE STRING "Backend: unavailable or freerdp")
set_property(CACHE MR_BRIDGE_BACKEND PROPERTY STRINGS unavailable freerdp)
set(MR_FREERDP_INCLUDE_DIR "" CACHE PATH "FreeRDP/WinPR/OpenSSL include root for the freerdp backend")

if(MR_BRIDGE_BACKEND STREQUAL "unavailable")
    set(_mr_bridge_backend_source src/backend_unavailable.c)
elseif(MR_BRIDGE_BACKEND STREQUAL "freerdp")
    if(NOT IS_DIRECTORY "${MR_FREERDP_INCLUDE_DIR}")
        message(FATAL_ERROR "MR_BRIDGE_BACKEND=freerdp requires MR_FREERDP_INCLUDE_DIR")
    endif()
    foreach(_mr_required_header freerdp/freerdp.h winpr/wtypes.h openssl/x509.h)
        if(NOT EXISTS "${MR_FREERDP_INCLUDE_DIR}/${_mr_required_header}")
            message(FATAL_ERROR "Missing ${_mr_required_header} under MR_FREERDP_INCLUDE_DIR")
        endif()
    endforeach()
    set(_mr_bridge_backend_source
        src/certificate_chain.c
        src/freerdp_backend.c
    )
else()
    message(FATAL_ERROR "Unknown MR_BRIDGE_BACKEND=${MR_BRIDGE_BACKEND}")
endif()

add_library(mremote_rdp_bridge STATIC
    ${_mr_bridge_backend_source}
    src/control_deadline.c
    src/input_command_queue.c
    src/rdp_bridge.c
    src/rdpsnd.c
    # ABI 6: the MACRDPX codec and key tables (git submodule).
    ${CMAKE_CURRENT_SOURCE_DIR}/../external/macrdpx/src/codec.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../external/macrdpx/src/keys.c
)
add_library(mremote::rdp_bridge ALIAS mremote_rdp_bridge)

target_compile_features(mremote_rdp_bridge PUBLIC c_std_11)
target_include_directories(mremote_rdp_bridge
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../external/macrdpx/include>
        $<INSTALL_INTERFACE:include>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_link_libraries(mremote_rdp_bridge PRIVATE Threads::Threads)

if(MR_BRIDGE_BACKEND STREQUAL "freerdp")
    target_include_directories(mremote_rdp_bridge SYSTEM PRIVATE "${MR_FREERDP_INCLUDE_DIR}")
endif()

if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
    target_compile_options(mremote_rdp_bridge PRIVATE -Wall -Wextra -Wpedantic)
    if(MR_BRIDGE_WARNINGS_AS_ERRORS)
        target_compile_options(mremote_rdp_bridge PRIVATE -Werror)
    endif()
endif()

if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
    if(NOT CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        message(FATAL_ERROR "MR_BRIDGE_SANITIZER requires Clang or GCC")
    endif()
    if(MR_BRIDGE_SANITIZER STREQUAL "address")
        set(_mr_sanitizer_flags -fsanitize=address,undefined -fno-omit-frame-pointer)
    elseif(MR_BRIDGE_SANITIZER STREQUAL "undefined")
        set(_mr_sanitizer_flags -fsanitize=undefined -fno-omit-frame-pointer)
    elseif(MR_BRIDGE_SANITIZER STREQUAL "thread")
        set(_mr_sanitizer_flags -fsanitize=thread -fno-omit-frame-pointer)
    else()
        message(FATAL_ERROR "Unknown MR_BRIDGE_SANITIZER=${MR_BRIDGE_SANITIZER}")
    endif()
    target_compile_options(mremote_rdp_bridge PRIVATE ${_mr_sanitizer_flags})
    target_link_options(mremote_rdp_bridge PRIVATE ${_mr_sanitizer_flags})
endif()

if(BUILD_TESTING)
    target_sources(mremote_rdp_bridge PRIVATE test_support/mock_backend.c)
    target_include_directories(mremote_rdp_bridge PRIVATE test_support/include)

    add_executable(mremote_rdp_bridge_contract_tests tests/contract_tests.c)
    target_compile_features(mremote_rdp_bridge_contract_tests PRIVATE c_std_11)
    target_include_directories(mremote_rdp_bridge_contract_tests PRIVATE
        test_support/include
        src
    )
    target_link_libraries(mremote_rdp_bridge_contract_tests PRIVATE
        mremote_rdp_bridge
        Threads::Threads
    )

    if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(mremote_rdp_bridge_contract_tests PRIVATE -Wall -Wextra -Wpedantic)
        if(MR_BRIDGE_WARNINGS_AS_ERRORS)
            target_compile_options(mremote_rdp_bridge_contract_tests PRIVATE -Werror)
        endif()
    endif()

    if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
        target_compile_options(mremote_rdp_bridge_contract_tests PRIVATE ${_mr_sanitizer_flags})
        target_link_options(mremote_rdp_bridge_contract_tests PRIVATE ${_mr_sanitizer_flags})
    endif()

    add_test(NAME mremote_rdp_bridge.contract COMMAND mremote_rdp_bridge_contract_tests)
    set_tests_properties(mremote_rdp_bridge.contract PROPERTIES TIMEOUT 20)

    add_executable(mremote_channel_contract_tests tests/channel_contract_tests.c)
    target_compile_features(mremote_channel_contract_tests PRIVATE c_std_11)
    target_include_directories(mremote_channel_contract_tests PRIVATE
        test_support/include
        src
    )
    target_link_libraries(mremote_channel_contract_tests PRIVATE
        mremote_rdp_bridge
        Threads::Threads
    )
    if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(mremote_channel_contract_tests PRIVATE
            -Wall -Wextra -Wpedantic
        )
        if(MR_BRIDGE_WARNINGS_AS_ERRORS)
            target_compile_options(mremote_channel_contract_tests PRIVATE -Werror)
        endif()
    endif()
    if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
        target_compile_options(mremote_channel_contract_tests PRIVATE ${_mr_sanitizer_flags})
        target_link_options(mremote_channel_contract_tests PRIVATE ${_mr_sanitizer_flags})
    endif()
    add_test(NAME mremote_channel.contract COMMAND mremote_channel_contract_tests)
    set_tests_properties(mremote_channel.contract PROPERTIES TIMEOUT 20)

    add_executable(mremote_abi2_contract_tests tests/abi2_contract_tests.c)
    target_compile_features(mremote_abi2_contract_tests PRIVATE c_std_11)
    target_include_directories(mremote_abi2_contract_tests PRIVATE
        test_support/include
        src
    )
    target_link_libraries(mremote_abi2_contract_tests PRIVATE
        mremote_rdp_bridge
        Threads::Threads
    )
    if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(mremote_abi2_contract_tests PRIVATE
            -Wall -Wextra -Wpedantic
        )
        if(MR_BRIDGE_WARNINGS_AS_ERRORS)
            target_compile_options(mremote_abi2_contract_tests PRIVATE -Werror)
        endif()
    endif()
    if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
        target_compile_options(mremote_abi2_contract_tests PRIVATE ${_mr_sanitizer_flags})
        target_link_options(mremote_abi2_contract_tests PRIVATE ${_mr_sanitizer_flags})
    endif()
    add_test(NAME mremote_abi2.contract COMMAND mremote_abi2_contract_tests)
    set_tests_properties(mremote_abi2.contract PROPERTIES TIMEOUT 20)

    add_executable(mremote_abi3_contract_tests tests/abi3_contract_tests.c)
    target_compile_features(mremote_abi3_contract_tests PRIVATE c_std_11)
    target_include_directories(mremote_abi3_contract_tests PRIVATE
        test_support/include
        src
    )
    target_link_libraries(mremote_abi3_contract_tests PRIVATE
        mremote_rdp_bridge
        Threads::Threads
    )
    if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(mremote_abi3_contract_tests PRIVATE
            -Wall -Wextra -Wpedantic
        )
        if(MR_BRIDGE_WARNINGS_AS_ERRORS)
            target_compile_options(mremote_abi3_contract_tests PRIVATE -Werror)
        endif()
    endif()
    if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
        target_compile_options(mremote_abi3_contract_tests PRIVATE ${_mr_sanitizer_flags})
        target_link_options(mremote_abi3_contract_tests PRIVATE ${_mr_sanitizer_flags})
    endif()
    add_test(NAME mremote_abi3.contract COMMAND mremote_abi3_contract_tests)
    set_tests_properties(mremote_abi3.contract PROPERTIES TIMEOUT 20)

    add_executable(mremote_abi4_contract_tests tests/abi4_contract_tests.c)
    target_compile_features(mremote_abi4_contract_tests PRIVATE c_std_11)
    target_include_directories(mremote_abi4_contract_tests PRIVATE
        test_support/include
        src
    )
    target_link_libraries(mremote_abi4_contract_tests PRIVATE
        mremote_rdp_bridge
        Threads::Threads
    )
    if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(mremote_abi4_contract_tests PRIVATE
            -Wall -Wextra -Wpedantic
        )
        if(MR_BRIDGE_WARNINGS_AS_ERRORS)
            target_compile_options(mremote_abi4_contract_tests PRIVATE -Werror)
        endif()
    endif()
    if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
        target_compile_options(mremote_abi4_contract_tests PRIVATE ${_mr_sanitizer_flags})
        target_link_options(mremote_abi4_contract_tests PRIVATE ${_mr_sanitizer_flags})
    endif()
    add_test(NAME mremote_abi4.contract COMMAND mremote_abi4_contract_tests)
    set_tests_properties(mremote_abi4.contract PROPERTIES TIMEOUT 20)

    if(APPLE)
        # VideoToolbox is on the host too: encode, then decode with the
        # bridge's own decoder.
        add_executable(mremote_h264_decoder_tests tests/h264_decoder_tests.c src/h264_decoder.c)
        target_compile_features(mremote_h264_decoder_tests PRIVATE c_std_11)
        target_include_directories(mremote_h264_decoder_tests PRIVATE src)
        target_link_libraries(mremote_h264_decoder_tests PRIVATE
            "-framework VideoToolbox" "-framework CoreMedia" "-framework CoreVideo"
            "-framework CoreFoundation"
        )
        if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
            target_compile_options(mremote_h264_decoder_tests PRIVATE ${_mr_sanitizer_flags})
            target_link_options(mremote_h264_decoder_tests PRIVATE ${_mr_sanitizer_flags})
        endif()
        add_test(NAME mremote_h264_decoder COMMAND mremote_h264_decoder_tests)
        set_tests_properties(mremote_h264_decoder PROPERTIES TIMEOUT 30)
    endif()

    add_executable(mremote_abi5_contract_tests tests/abi5_contract_tests.c)
    target_compile_features(mremote_abi5_contract_tests PRIVATE c_std_11)
    target_include_directories(mremote_abi5_contract_tests PRIVATE
        test_support/include
        src
    )
    target_link_libraries(mremote_abi5_contract_tests PRIVATE
        mremote_rdp_bridge
        Threads::Threads
    )
    if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(mremote_abi5_contract_tests PRIVATE
            -Wall -Wextra -Wpedantic
        )
        if(MR_BRIDGE_WARNINGS_AS_ERRORS)
            target_compile_options(mremote_abi5_contract_tests PRIVATE -Werror)
        endif()
    endif()
    if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
        target_compile_options(mremote_abi5_contract_tests PRIVATE ${_mr_sanitizer_flags})
        target_link_options(mremote_abi5_contract_tests PRIVATE ${_mr_sanitizer_flags})
    endif()
    add_test(NAME mremote_abi5.contract COMMAND mremote_abi5_contract_tests)
    set_tests_properties(mremote_abi5.contract PROPERTIES TIMEOUT 20)

    add_executable(mremote_abi6_contract_tests tests/abi6_contract_tests.c)
    target_compile_features(mremote_abi6_contract_tests PRIVATE c_std_11)
    target_include_directories(mremote_abi6_contract_tests PRIVATE
        test_support/include
        src
    )
    target_link_libraries(mremote_abi6_contract_tests PRIVATE
        mremote_rdp_bridge
        Threads::Threads
    )
    if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(mremote_abi6_contract_tests PRIVATE
            -Wall -Wextra -Wpedantic
        )
        if(MR_BRIDGE_WARNINGS_AS_ERRORS)
            target_compile_options(mremote_abi6_contract_tests PRIVATE -Werror)
        endif()
    endif()
    if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
        target_compile_options(mremote_abi6_contract_tests PRIVATE ${_mr_sanitizer_flags})
        target_link_options(mremote_abi6_contract_tests PRIVATE ${_mr_sanitizer_flags})
    endif()
    add_test(NAME mremote_abi6.contract COMMAND mremote_abi6_contract_tests)
    set_tests_properties(mremote_abi6.contract PROPERTIES TIMEOUT 20)

    add_executable(mremote_abi7_contract_tests tests/abi7_contract_tests.c)
    target_compile_features(mremote_abi7_contract_tests PRIVATE c_std_11)
    target_include_directories(mremote_abi7_contract_tests PRIVATE
        test_support/include
        src
    )
    target_link_libraries(mremote_abi7_contract_tests PRIVATE
        mremote_rdp_bridge
        Threads::Threads
    )
    if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(mremote_abi7_contract_tests PRIVATE
            -Wall -Wextra -Wpedantic
        )
        if(MR_BRIDGE_WARNINGS_AS_ERRORS)
            target_compile_options(mremote_abi7_contract_tests PRIVATE -Werror)
        endif()
    endif()
    if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
        target_compile_options(mremote_abi7_contract_tests PRIVATE ${_mr_sanitizer_flags})
        target_link_options(mremote_abi7_contract_tests PRIVATE ${_mr_sanitizer_flags})
    endif()
    add_test(NAME mremote_abi7.contract COMMAND mremote_abi7_contract_tests)
    set_tests_properties(mremote_abi7.contract PROPERTIES TIMEOUT 20)

    add_executable(mremote_rdpsnd_contract_tests tests/rdpsnd_contract_tests.c)
    target_compile_features(mremote_rdpsnd_contract_tests PRIVATE c_std_11)
    target_link_libraries(mremote_rdpsnd_contract_tests PRIVATE
        mremote_rdp_bridge
        Threads::Threads
    )
    if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(mremote_rdpsnd_contract_tests PRIVATE -Wall -Wextra -Wpedantic)
        if(MR_BRIDGE_WARNINGS_AS_ERRORS)
            target_compile_options(mremote_rdpsnd_contract_tests PRIVATE -Werror)
        endif()
    endif()
    if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
        target_compile_options(mremote_rdpsnd_contract_tests PRIVATE ${_mr_sanitizer_flags})
        target_link_options(mremote_rdpsnd_contract_tests PRIVATE ${_mr_sanitizer_flags})
    endif()
    add_test(NAME mremote_rdpsnd.contract COMMAND mremote_rdpsnd_contract_tests)
    set_tests_properties(mremote_rdpsnd.contract PROPERTIES TIMEOUT 20)

    add_executable(mremote_input_command_queue_tests
        tests/input_command_queue_tests.c
    )
    target_compile_features(mremote_input_command_queue_tests PRIVATE c_std_11)
    target_include_directories(mremote_input_command_queue_tests PRIVATE
        include
        src
    )
    target_link_libraries(mremote_input_command_queue_tests PRIVATE
        mremote_rdp_bridge
    )
    if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(mremote_input_command_queue_tests PRIVATE
            -Wall -Wextra -Wpedantic
        )
        if(MR_BRIDGE_WARNINGS_AS_ERRORS)
            target_compile_options(mremote_input_command_queue_tests PRIVATE -Werror)
        endif()
    endif()
    if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
        target_compile_options(mremote_input_command_queue_tests PRIVATE
            ${_mr_sanitizer_flags}
        )
        target_link_options(mremote_input_command_queue_tests PRIVATE
            ${_mr_sanitizer_flags}
        )
    endif()
    add_test(
        NAME mremote_input_command_queue.contract
        COMMAND mremote_input_command_queue_tests
    )
    set_tests_properties(mremote_input_command_queue.contract PROPERTIES TIMEOUT 20)

    add_executable(mremote_control_deadline_tests
        tests/control_deadline_tests.c
    )
    target_compile_features(mremote_control_deadline_tests PRIVATE c_std_11)
    target_include_directories(mremote_control_deadline_tests PRIVATE src)
    target_link_libraries(mremote_control_deadline_tests PRIVATE
        mremote_rdp_bridge
    )
    if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(mremote_control_deadline_tests PRIVATE
            -Wall -Wextra -Wpedantic
        )
        if(MR_BRIDGE_WARNINGS_AS_ERRORS)
            target_compile_options(mremote_control_deadline_tests PRIVATE -Werror)
        endif()
    endif()
    if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
        target_compile_options(mremote_control_deadline_tests PRIVATE
            ${_mr_sanitizer_flags}
        )
        target_link_options(mremote_control_deadline_tests PRIVATE
            ${_mr_sanitizer_flags}
        )
    endif()
    add_test(
        NAME mremote_control_deadline.contract
        COMMAND mremote_control_deadline_tests
    )
    set_tests_properties(mremote_control_deadline.contract PROPERTIES TIMEOUT 20)

    if(MR_BRIDGE_CERTIFICATE_TESTS)
        find_package(OpenSSL REQUIRED COMPONENTS Crypto)
        add_executable(mremote_certificate_chain_tests
            tests/certificate_chain_tests.c
            src/certificate_chain.c
        )
        target_compile_features(mremote_certificate_chain_tests PRIVATE c_std_11)
        target_include_directories(mremote_certificate_chain_tests PRIVATE
            include
            src
        )
        target_link_libraries(mremote_certificate_chain_tests PRIVATE OpenSSL::Crypto)
        if(CMAKE_C_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
            target_compile_options(mremote_certificate_chain_tests PRIVATE
                -Wall -Wextra -Wpedantic
            )
            if(MR_BRIDGE_WARNINGS_AS_ERRORS)
                target_compile_options(mremote_certificate_chain_tests PRIVATE -Werror)
            endif()
        endif()
        if(NOT MR_BRIDGE_SANITIZER STREQUAL "none")
            target_compile_options(mremote_certificate_chain_tests PRIVATE ${_mr_sanitizer_flags})
            target_link_options(mremote_certificate_chain_tests PRIVATE ${_mr_sanitizer_flags})
        endif()
        add_test(NAME mremote_certificate_chain.contract COMMAND mremote_certificate_chain_tests)
        set_tests_properties(mremote_certificate_chain.contract PROPERTIES TIMEOUT 20)
    endif()
endif()
