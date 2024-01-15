#!/usr/bin/env bash
##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

function _chalk_setup_either {
            COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --store-password --no-store-password --key-file" -- ${_CHALK_CUR_WORD}))
}

function _chalk_setup_completions {
    case ${COMP_WORDS[${_CHALK_CUR_IX}]} in
        gen)
            _chalk_setup_either
            ;;
        load)
            _chalk_setup_either
            ;;
        *)
            COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --store-password --key-file gen load" -- ${_CHALK_CUR_WORD}))
            ;;
        esac
}

function _chalk_delete_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
    COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --dry-run --no-dry-run --no-dry-run --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --recursive --no-recursive --report-template" -- ${_CHALK_CUR_WORD}))
    fi
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
# { "MAGIC" : "dadfedabbadabbed", "CHALK_ID" : "6MRP2S-HJCC-V3GS-HSC4RK", "CHALK_VERSION" : "0.2.2", "TIMESTAMP_WHEN_CHALKED" : 1705362980499, "DATETIME_WHEN_CHALKED" : "2024-01-15T18:56:19.596-05:00", "ARTIFACT_TYPE" : "bash", "ARTIFACT_VERSION" : "0.2.2", "AUTHOR" : "Miroslav Shubernetskiy <miroslav@miki725.com> 1705362897 -0500", "CHALK_PTR" : "This mark determines when to update the script. If there is no mark, or the mark is invalid it will be replaced.  To customize w/o Chalk disturbing it when it can update, add a valid  mark with a version key higher than the current chalk verison, or  use version 0.0.0 to prevent updates", "COMMITTER" : "Miroslav Shubernetskiy <miroslav@miki725.com> 1705362897 -0500", "COMMIT_SIGNED" : false, "DATE_AUTHORED" : "Mon Jan 15 18:54:57 2024 -0500", "DATE_COMMITTED" : "Mon Jan 15 18:54:57 2024 -0500", "HASH" : "51af2c68f9a19659ab9810cc804d75aa75bb0dc1a2e18f5fb0f1e2083ae1e2da", "INJECTOR_COMMIT_ID" : "0f92a1fbdf2a72fac7d7be162aa926d71c9dcbf5", "ORIGIN_URI" : "git@github.com:crashappsec/chalk.git", "METADATA_ID" : "RYWB7G-8KQT-CAGX-DKDTBK" }
