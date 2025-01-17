# .rst: FindPostgreSQL
# --------------------
#
# Builds a PostgreSQL installation. As opposed to finding a system-wide installation, this module
# will download and build PostgreSQL with debug enabled.
#
# By default, it'll download the latest known version of PostgreSQL (at the time of last update)
# unless `PGVER` variable is set. `PGVER` can be either a major version like `15` which will be aliased
# to the latest known minor version, or a full version.
#
# This module defines the following variables
#
# ::
#
# PostgreSQL_LIBRARIES - the PostgreSQL libraries needed for linking
#
# PostgreSQL_INCLUDE_DIRS - include directories
#
# PostgreSQL_SERVER_INCLUDE_DIRS - include directories for server programming
#
# PostgreSQL_LIBRARY_DIRS  - link directories for PostgreSQL libraries
#
# PostgreSQL_EXTENSION_DIR  - the directory for extensions
#
# PostgreSQL_SHARED_LINK_OPTIONS  - options for shared libraries
#
# PostgreSQL_LINK_OPTIONS  - options for static libraries and executables
#
# PostgreSQL_VERSION_STRING - the version of PostgreSQL found (since CMake
# 2.8.8)
#
# ----------------------------------------------------------------------------
# History: This module is derived from the existing FindPostgreSQL.cmake and try
# to use most of the existing output variables of that module, but uses
# `pg_config` to extract the necessary information instead and add a macro for
# creating extensions. The use of `pg_config` is aligned with how the PGXS code
# distributed with PostgreSQL itself works.

# Copyright 2022 Omnigres Contributors
# Copyright 2020 Mats Kindahl
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.

# add_postgresql_extension(NAME ...)
#
# VERSION Version of the extension. Is used when generating the control file.
# Required.
#
# ENCODING Encoding for the control file. Optional.
#
# COMMENT Comment for the control file. Optional.
#
# SOURCES List of source files to compile for the extension.
#
# REQUIRES List of extensions that are required by this extension.
#
# TESTS_REQUIRE List of extensions that are required by tests.
#
# SCRIPTS Script files.
#
# SCRIPT_TEMPLATES Template script files.
#
# REGRESS Regress tests.
#
# SCHEMA Extension schema.
#
# RELOCATABLE Is extension relocatable
#
# SHARED_PRELOAD Is this a shared preload extension
#
#
# Defines the following targets:
#
# psql_NAME   Start extension it in a fresh database and connects with psql
# (port assigned randomly)
#
# NAME_update_results Updates pg_regress test expectations to match results
# test_verbose_NAME Runs tests verbosely
find_program(PGCLI pgcli)

function(add_postgresql_extension NAME)
    set(_optional SHARED_PRELOAD)
    set(_single VERSION ENCODING SCHEMA RELOCATABLE)
    set(_multi SOURCES SCRIPTS SCRIPT_TEMPLATES REQUIRES TESTS_REQUIRE REGRESS)
    cmake_parse_arguments(_ext "${_optional}" "${_single}" "${_multi}" ${ARGN})

    if(NOT _ext_VERSION)
        message(FATAL_ERROR "Extension version not set")
    endif()

    # Here we are assuming that there is at least one source file, which is
    # strictly speaking not necessary for an extension. If we do not have source
    # files, we need to create a custom target and attach properties to that. We
    # expect the user to be able to add target properties after creating the
    # extension.
    add_library(${NAME} MODULE ${_ext_SOURCES})

    # Proactively support dynpgext so that its caching late bound calls most efficiently
    # on macOS
    if(APPLE)
        file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/dynpgext.c" [=[
#undef DYNPGEXT_SUPPLEMENTARY
#define DYNPGEXT_MAIN
#include <dynpgext.h>
    ]=])
        target_sources(${NAME} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/dynpgext.c")
        target_link_libraries(${NAME} dynpgext)
        target_compile_definitions(${NAME} PUBLIC DYNPGEXT_SUPPLEMENTARY)
    endif()

    target_compile_definitions(${NAME} PUBLIC "$<$<NOT:$<STREQUAL:${CMAKE_BUILD_TYPE},Release>>:DEBUG>")
    target_compile_definitions(${NAME} PUBLIC "$<$<NOT:$<STREQUAL:${CMAKE_BUILD_TYPE},Release>>:USE_ASSERT_CHECKING>")
    target_compile_definitions(${NAME} PUBLIC "EXT_VERSION=\"${_ext_VERSION}\"")
    target_compile_definitions(${NAME} PUBLIC "EXT_SCHEMA=\"${_ext_SCHEMA}\"")

    set(_link_flags "${PostgreSQL_SHARED_LINK_OPTIONS}")

    foreach(_dir ${PostgreSQL_SERVER_LIBRARY_DIRS})
        set(_link_flags "${_link_flags} -L${_dir}")
    endforeach()

    set(_share_dir "${CMAKE_BINARY_DIR}/pg-share")
    file(COPY "${_pg_sharedir}/" DESTINATION "${_share_dir}")
    set(_ext_dir "${_share_dir}/extension")
    file(MAKE_DIRECTORY ${_ext_dir})

    # Collect and build script files to install
    set(_script_files)

    foreach(_script_file ${_ext_SCRIPTS})
        file(CREATE_LINK "${CMAKE_CURRENT_SOURCE_DIR}/${_script_file}" "${_ext_dir}/${_script_file}" SYMBOLIC)
        list(APPEND _script_files ${_ext_dir}/${_script_file})
    endforeach()

    foreach(_template ${_ext_SCRIPT_TEMPLATES})
        string(REGEX REPLACE "\.in$" "" _script ${_template})
        configure_file(${_template} ${_script} @ONLY)
        list(APPEND _script_files ${_ext_dir}/${_script})
        message(
            STATUS "Building script file ${_script} from template file ${_template}")
    endforeach()

    if(APPLE)
        set(_link_flags "${_link_flags} -bundle -bundle_loader ${PG_BINARY}")
    endif()

    set_target_properties(
        ${NAME}
        PROPERTIES
        PREFIX ""
        SUFFIX "--${_ext_VERSION}.so"
        LINK_FLAGS "${_link_flags}"
        POSITION_INDEPENDENT_CODE ON)

    target_include_directories(
        ${NAME}
        PRIVATE ${PostgreSQL_SERVER_INCLUDE_DIRS}
        PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

    set(_pkg_dir "${CMAKE_BINARY_DIR}/packaged")

    # Generate control file at build time (which is when GENERATE evaluate the
    # contents). We do not know the target file name until then.
    set(_control_file "${_ext_dir}/${NAME}--${_ext_VERSION}.control")
    file(
        GENERATE
        OUTPUT ${_control_file}
        CONTENT
        "module_pathname = '${CMAKE_CURRENT_BINARY_DIR}/$<TARGET_FILE_NAME:${NAME}>'
$<$<NOT:$<BOOL:${_ext_COMMENT}>>:#>comment = '${_ext_COMMENT}'
$<$<NOT:$<BOOL:${_ext_ENCODING}>>:#>encoding = '${_ext_ENCODING}'
$<$<NOT:$<BOOL:${_ext_REQUIRES}>>:#>requires = '$<JOIN:${_ext_REQUIRES},$<COMMA>>'
$<$<NOT:$<BOOL:${_ext_SCHEMA}>>:#>schema = ${_ext_SCHEMA}
$<$<NOT:$<BOOL:${_ext_RELOCATABLE}>>:#>relocatable = ${_ext_RELOCATABLE}
")
    # Pacaged control file
    set(_packaged_control_file "${_pkg_dir}/extension/${NAME}--${_ext_VERSION}.control")
    file(
        GENERATE
        OUTPUT ${_packaged_control_file}
        CONTENT
        "module_pathname = '$libdir/$<TARGET_FILE_NAME:${NAME}>'
$<$<NOT:$<BOOL:${_ext_COMMENT}>>:#>comment = '${_ext_COMMENT}'
$<$<NOT:$<BOOL:${_ext_ENCODING}>>:#>encoding = '${_ext_ENCODING}'
$<$<NOT:$<BOOL:${_ext_REQUIRES}>>:#>requires = '$<JOIN:${_ext_REQUIRES},$<COMMA>>'
$<$<NOT:$<BOOL:${_ext_SCHEMA}>>:#>schema = ${_ext_SCHEMA}
$<$<NOT:$<BOOL:${_ext_RELOCATABLE}>>:#>relocatable = ${_ext_RELOCATABLE}
")
 
    # Default control file
    set(_default_control_file "${_ext_dir}/${NAME}.control")
    file(
        GENERATE
        OUTPUT ${_default_control_file}
        CONTENT
        "default_version = '${_ext_VERSION}'
")
    # Packaged default control file
    set(_packaged_default_control_file "${_pkg_dir}/extension/${NAME}.control")
    file(
        GENERATE
        OUTPUT ${_packaged_default_control_file}
        CONTENT
        "default_version = '${_ext_VERSION}'
")

   add_custom_target(package_${NAME}_extension
            WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
            COMMAND
            ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_CURRENT_BINARY_DIR}/$<TARGET_FILE_NAME:${NAME}>"
            ${_pkg_dir})

    add_custom_target(package_${NAME}_scripts
            WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
            COMMAND
            ${CMAKE_COMMAND} -E copy_if_different
            ${_script_files}
            ${_pkg_dir}/extension)

    if(NOT TARGET package)
            add_custom_target(package)
    endif()
    add_dependencies(package package_${NAME}_extension package_${NAME}_scripts)


    if(_ext_REGRESS)
        foreach(_test ${_ext_REGRESS})
            set(_sql_file "${CMAKE_CURRENT_SOURCE_DIR}/sql/${_test}.sql")
            set(_out_file "${CMAKE_CURRENT_SOURCE_DIR}/expected/${_test}.out")

            if(NOT EXISTS "${_sql_file}")
                message(FATAL_ERROR "Test file '${_sql_file}' does not exist!")
            endif()

            if(NOT EXISTS "${_out_file}")
                file(WRITE "${_out_file}")
                message(STATUS "Created empty file ${_out_file}")
            endif()
        endforeach()

        if(PG_REGRESS)
            set(_loadextensions)
            set(_extra_config)

            foreach(requirement ${_ext_REQUIRES})
                list(APPEND _ext_TESTS_REQUIRE ${requirement})
            endforeach()

            list(REMOVE_DUPLICATES _ext_TESTS_REQUIRE)

            foreach(req ${_ext_TESTS_REQUIRE})
                string(APPEND _loadextensions "--load-extension=${req} ")

                if(req STREQUAL "omni_ext")
                    set(_extra_config "shared_preload_libraries=\\\'$<TARGET_FILE:omni_ext>\\\'")
                endif()
            endforeach()

            list(JOIN _ext_REGRESS " " _ext_REGRESS_ARGS)
            file(GENERATE OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/test_${NAME}
                CONTENT "#! /usr/bin/env bash
# Pick random port
while true
do
    export PORT=$(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
    status=\"$(nc -z 127.0.0.1 $random_port < /dev/null &>/dev/null; echo $?)\"
    if [ \"${status}\" != \"0\" ]; then
        echo \"Using port $PORT\";
        break;
    fi
done
export tmpdir=$(mktemp -d)
echo local all all trust > \"$tmpdir/pg_hba.conf\"
echo host all all all trust >> \"$tmpdir/pg_hba.conf\"
echo hba_file=\\\'$tmpdir/pg_hba.conf\\\' > \"$tmpdir/postgresql.conf\"
$<IF:$<BOOL:${_ext_SHARED_PRELOAD}>,echo shared_preload_libraries='${CMAKE_CURRENT_BINARY_DIR}/$<TARGET_FILE_NAME:${NAME}>',echo> >> $tmpdir/postgresql.conf
echo ${_extra_config} >> $tmpdir/postgresql.conf
echo max_worker_processes = 64 >> $tmpdir/postgresql.conf
PGSHAREDIR=${_share_dir} \
EXTENSION_SOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR} \
${PG_REGRESS} --temp-instance=\"$tmpdir/instance\" --inputdir=${CMAKE_CURRENT_SOURCE_DIR} \
--dbname=\"${NAME}\" \
--temp-config=\"$tmpdir/postgresql.conf\" \
--outputdir=\"${CMAKE_CURRENT_BINARY_DIR}/${NAME}\" \
${_loadextensions} \
--load-extension=${NAME} --host=0.0.0.0 --port=$PORT ${_ext_REGRESS_ARGS}
"
                FILE_PERMISSIONS OWNER_EXECUTE OWNER_READ OWNER_WRITE
            )
            add_test(
                NAME ${NAME}
                WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
                COMMAND ${CMAKE_CURRENT_BINARY_DIR}/test_${NAME}
            )
        endif()

        add_custom_target(
                ${NAME}_update_results
                COMMAND
                ${CMAKE_COMMAND} -E copy_if_different
                ${CMAKE_CURRENT_BINARY_DIR}/${NAME}/results/*.out
                ${CMAKE_CURRENT_SOURCE_DIR}/expected)
        if(NOT TARGET update_test_results)
            add_custom_target(update_test_results)
        endif()
        add_dependencies(update_test_results ${NAME}_update_results)
    endif()

    if(INITDB AND CREATEDB AND (PSQL OR PGCLI) AND PG_CTL)
        if(PGCLI)
            set(_cli ${PGCLI})
        else()
            set(_cli ${PSQL})
        endif()

        file(GENERATE OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/psql_${NAME}
            CONTENT "#! /usr/bin/env bash
# Pick random port
while true
do
    export PGPORT=$(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
    status=\"$(nc -z 127.0.0.1 $random_port < /dev/null &>/dev/null; echo $?)\"
    if [ \"${status}\" != \"0\" ]; then
        echo \"Using port $PGPORT\";
        break;
    fi
done
export EXTENSION_SOURCE_DIR=\"${CMAKE_CURRENT_SOURCE_DIR}\"
rm -rf \"${CMAKE_CURRENT_BINARY_DIR}/data/${NAME}\"
${INITDB} -D \"${CMAKE_CURRENT_BINARY_DIR}/data/${NAME}\" --no-clean --no-sync
export SOCKDIR=$(mktemp -d)
echo host all all all trust >>  \"${CMAKE_CURRENT_BINARY_DIR}/data/${NAME}/pg_hba.conf\"
PGSHAREDIR=${_share_dir} \
${PG_CTL} start -D \"${CMAKE_CURRENT_BINARY_DIR}/data/${NAME}\" \
-o \"-c max_worker_processes=64 -c listen_addresses=* -c port=$PGPORT $<IF:$<BOOL:${_ext_SHARED_PRELOAD}>,-c shared_preload_libraries='$<TARGET_FILE:${NAME}>$<COMMA>$<TARGET_FILE:omni_ext>',-c shared_preload_libraries='$<TARGET_FILE:omni_ext>'>\" \
-o -F -o -k -o \"$SOCKDIR\"
${CREATEDB} -h \"$SOCKDIR\" ${NAME}
${_cli} -h \"$SOCKDIR\" ${NAME}
${PG_CTL} stop -D  \"${CMAKE_CURRENT_BINARY_DIR}/data/${NAME}\" -m smart
"
            FILE_PERMISSIONS OWNER_EXECUTE OWNER_READ OWNER_WRITE
        )
        add_custom_target(psql_${NAME}
            WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
            COMMAND ${CMAKE_CURRENT_BINARY_DIR}/psql_${NAME})
        add_dependencies(psql_${NAME} ${NAME})
    endif()

    if(PG_REGRESS)
        # We add a custom target to get output when there is a failure.
        add_custom_target(
            test_verbose_${NAME} COMMAND ${CMAKE_CTEST_COMMAND} --force-new-ctest-process
            --verbose --output-on-failure)
    endif()
endfunction()
