#!/usr/bin/env bash
##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

function _chalk_setup_completions {
    case ${COMP_WORDS[${_CHALK_CUR_IX}]} in
        *)
            COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior" -- ${_CHALK_CUR_WORD}))
            ;;
        esac
}

function _chalk_delete_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
    COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --dry-run --no-dry-run --no-dry-run --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --recursive --no-recursive --report-template" -- ${_CHALK_CUR_WORD}))
    fi
}

function _chalk_docker_completions {
    _command_offset 1
}

function _chalk_load_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
        COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --replace --no-replace --update-arch-binaries --no-update-arch-binaries --params --no-params --validation --no-validation --validation-warning --no-validation-warning" -- ${_CHALK_CUR_WORD}))
    fi

    if [[ $_CHALK_CUR_IX -le $COMP_CWORD ]] ; then
        if [ ${COMP_WORDS[${_CHALK_CUR_IX}]::1}  = "-" ] ; then
            _chalk_shift_one
            _chalk_load_completions
        fi
        # Else, already got a file name so nothing to complete.
    fi
}

function _chalk_dump_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
        COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --validation --no-validation --validation-warning --no-validation-warning" -- ${_CHALK_CUR_WORD}))
    else
        EXTRA=($(compgen -W "params cache" -- ${_CHALK_CUR_WORD}))
        COMPREPLY+=(${EXTRA[@]})
    fi

    if [[ $_CHALK_CUR_IX -le $COMP_CWORD ]] ; then
        if [ ${COMP_WORDS[${_CHALK_CUR_IX}]::1}  = "-" ] ; then
            _chalk_shift_one
            _chalk_load_completions
        fi
        # Else, already got a file name so nothing to complete.
    fi
}

function _chalk_exec_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
        COMPREPLY=($(compgen -W "-- --color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --exec-command-name --chalk-as-parent --no-chalk-as-parent --heartbeat --no-heartbeat --report-template" -- ${_CHALK_CUR_WORD}))
    fi
}

function _chalk_help_completions {
    COMPREPLY=($(compgen -W "metadata keys search templates output reports reporting plugins insert delete env dump load config version docker exec extract setup commands configurations conffile configs conf topics builtins" -- ${_CHALK_CUR_WORD}))
}

function _chalk_extract_completions {
    if [[ ${_CHALK_CUR_WORD::1} = "-" ]] ; then
    COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --recursive --no-recursive --report-template --search-layers --no-search-layers" -- ${_CHALK_CUR_WORD}))
    else
        COMPREPLY=($(compgen -W "images containers all" -- ${_CHALK_CUR_WORD}))
    fi
}

function _chalk_insert_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
    COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --run-sbom-tools --no-run-sbom-tools --run-sast-tools --no-run-sast-tools --use-report-cache --no-use-report-cache --virtual --no-virtual --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --recursive --no-recursive --mark-template --report-template" -- ${_CHALK_CUR_WORD}))
    fi
}

function _chalk_toplevel_completions {
    case ${COMP_WORDS[${_CHALK_CUR_IX}]} in
        insert)
            _chalk_shift_one
            _chalk_insert_completions
            ;;
        extract)
            _chalk_shift_one
            _chalk_extract_completions
            ;;
        delete)
            _chalk_shift_one
            _chalk_delete_completions
            ;;
        env)
            _chalk_shift_one
            _chalk_env_completions
            ;;
        exec)
            _chalk_shift_one
            _chalk_exec_completions
            ;;
        dump)
            _chalk_shift_one
            _chalk_dump_completions
            ;;
        load)
            _chalk_shift_one
            _chalk_load_completions
            ;;
        version)
            _chalk_shift_one
            _chalk_version_completions
            ;;
        docker)
            _chalk_shift_one
            _chalk_docker_completions
            ;;
        setup)
            _chalk_shift_one
            _chalk_setup_completions
            ;;
        help)
            _chalk_shift_one
            _chalk_help_completions
            ;;
        *)
            if [[ $_CHALK_CUR_IX -le $COMP_CWORD ]] ; then
                _chalk_shift_one
                _chalk_toplevel_completions
            else
                COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --virtual --no-virtual --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --wrap --no-wrap --pager --no-pager extract insert delete env exec config dump load version docker setup help helpdump" -- ${_CHALK_CUR_WORD}))
            fi
            ;;
    esac
}

function _chalk_shift_one {
    let "_CHALK_CUR_IX++"
}

function _chalk_completions {

    _CHALK_CUR_IX=0
    _CHALK_CUR_WORD=${2}
    _CHALK_PREV=${3}

    _chalk_toplevel_completions
}

complete -F _chalk_completions chalk
# { "MAGIC" : "dadfedabbadabbed", "CHALK_ID" : "CCVP2S-HSCR-VK6C-3569H3", "CHALK_VERSION" : "0.3.3", "TIMESTAMP_WHEN_CHALKED" : 1710356599979, "DATETIME_WHEN_CHALKED" : "2024-03-13T15:03:18.901-04:00", "ARTIFACT_TYPE" : "bash", "AUTHOR" : "Miroslav Shubernetskiy <miroslav@miki725.com> 1710352293 -0400", "BRANCH" : "ms", "CHALK_RAND" : "63b2eb8e1ecca0bc", "CODE_OWNERS" : "* @viega\n", "COMMITTER" : "Miroslav Shubernetskiy <miroslav@miki725.com> 1710352893 -0400", "COMMIT_ID" : "5f95367b955256bb92254a5bddaea6e5285a29f6", "COMMIT_MESSAGE" : "build: bumping con4m to include get(dict, \"key\")\n\nits used in connect.c4m", "COMMIT_SIGNED" : true, "DATE_AUTHORED" : "Wed Mar 13 13:51:33 2024 -0400", "DATE_COMMITTED" : "Wed Mar 13 14:01:33 2024 -0400", "HASH" : "c7af9f730e2b519880efe4be912469fa3bf7276a13a8dc84f2b4b6d4abad2ac7", "INJECTOR_COMMIT_ID" : "e96746336a5dd6618d4a8d5eae7a5542d048f301", "ORIGIN_URI" : "git@github.com:crashappsec/chalk.git", "PLATFORM_WHEN_CHALKED" : "GNU/Linux x86_64", "METADATA_ID" : "2BNPPM-H38H-SWDQ-19XTT8" }
