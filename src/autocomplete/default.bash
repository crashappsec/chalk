#!/usr/bin/env bash
##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##


# Basic bash completion script. Con4m should start generating these.
# Until then, maintain it manually.


function _chalk_setup_either {
            COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --skip-summary-report --no-skip-summary-report --store-password --no-store-password --key-file" -- ${_CHALK_CUR_WORD}))
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
            COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --skip-summary-report --no-skip-summary-report --store-password --key-file gen load" -- ${_CHALK_CUR_WORD}))
            ;;
        esac
}

function _chalk_delete_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
    COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config--use-report-cache --no-use-report-cache --dry-run --no-dry-run --no-dry-run --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --skip-summary-report --no-skip-summary-report --recursive --no-recursive --report-template" -- ${_CHALK_CUR_WORD}))
    else
        _filedir
    fi
}

function _chalk_load_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
        COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --replace --no-replace --validation --no-validation --validation-warning --no-validation-warning" -- ${_CHALK_CUR_WORD}))
    fi

    if [[ $_CHALK_CUR_IX -le $COMP_CWORD ]] ; then
        if [ ${COMP_WORDS[${_CHALK_CUR_IX}]::1}  = "-" ] ; then
            _chalk_shift_one
            _chalk_load_completions
        fi
        # Else, already got a file name so nothing to complete.
    else
        _filedir
    fi
}

function _chalk_dump_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
        COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --validation --no-validation --validation-warning --no-validation-warning" -- ${_CHALK_CUR_WORD}))
    fi

    if [[ $_CHALK_CUR_IX -le $COMP_CWORD ]] ; then
        if [ ${COMP_WORDS[${_CHALK_CUR_IX}]::1}  = "-" ] ; then
            _chalk_shift_one
            _chalk_load_completions
        fi
        # Else, already got a file name so nothing to complete.
    else
        _filedir
    fi
}


function _chalk_exec_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
        COMPREPLY=($(compgen -W "-- --color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --skip-summary-report --no-skip-summary-report --exec-command-name --chalk-as-parent --no-chalk-as-parent --heartbeat --no-heartbeat --report-template" -- ${_CHALK_CUR_WORD}))
    else
        if [ ${_CHALK_PREV} = "--exec-command-name" ] ; then
            _command
        fi
    fi
}

function _chalk_help_completions {
    COMPREPLY=($(compgen -W "metadata keys search templates output reports reporting plugins insert delete env dump load config version docker exec extract setup commands configurations conffile configs conf topics builtins" -- ${_CHALK_CUR_WORD}))
}

function _chalk_extract_completions {
    if [[ ${_CHALK_CUR_WORD::1} = "-" ]] ; then
    COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --skip-summary-report --no-skip-summary-report --recursive --no-recursive --report-template --search-layers --no-search-layers" -- ${_CHALK_CUR_WORD}))
    else
        _filedir
        EXTRA=($(compgen -W "images containers all" -- ${_CHALK_CUR_WORD}))
        COMPREPLY+=(${EXTRA[@]})
    fi
}

function _chalk_insert_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
    COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --run-sbom-tools --no-run-sbom-tools --run-sast-tools --no-run-sast-tools --use-report-cache --no-use-report-cache --virtual --no-virtual --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --skip-summary-report --no-skip-summary-report --recursive --no-recursive --mark-template --report-template" -- ${_CHALK_CUR_WORD}))
    else
        _filedir
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
                COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --show-config --no-show-config --use-report-cache --no-use-report-cache --virtual --no-virtual --debug --no-debug --skip-command-report --no-skip-command-report --symlink-behavior --skip-summary-report --no-skip-summary-report --wrap --no-wrap extract insert delete env exec config dump load version docker setup help helpdump" -- ${_CHALK_CUR_WORD}))
            fi
            ;;
    esac
}

function _chalk_shift_one {
    let "_CHALK_CUR_IX++"
}

function _chalk_completions {

    _get_comp_words_by_ref cur prev words cword

    _CHALK_CUR_IX=0
    _CHALK_CUR_WORD=${2}
    _CHALK_PREV=${3}

    _chalk_toplevel_completions
}

complete -F _chalk_completions chalk
# { "MAGIC" : "dadfedabbadabbed", "CHALK_ID" : "6SJ64D-K36W-TK6R-B668W6", "CHALK_VERSION" : "0.1.1", "TIMESTAMP_WHEN_CHALKED" : 1697041152342, "DATETIME_WHEN_CHALKED" : "2023-10-11T12:19:10.246-04:00", "ARTIFACT_TYPE" : "bash", "ARTIFACT_VERSION" : "0.1.2", "CHALK_PTR" : "This mark determines when to update the script. If there is no mark, or the mark is invalid it will be replaced.  To customize w/o Chalk disturbing it when it can update, add a valid  mark with a version key higher than the current chalk verison, or  use version 0.0.0 to prevent updates", "HASH" : "6db6c753af28acc7ab086e1a939307b5f00ceb181d553a2442eb4c683c67c760", "INJECTOR_COMMIT_ID" : "2e08a98a7d6767474493fe833fded6cf44958a25", "INJECTOR_PUBLIC_KEY" : "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEZk+qlbClhYKUHs+beXAsN/ZBCyDd\n/nNMOdXhIQuO2C2EReYialwR6yunTEvjnehRT501eQnBymMNtPfYbTnM4A==\n-----END PUBLIC KEY-----\n", "ORIGIN_URI" : "git@github.com:crashappsec/chalk.git", "SIGNING" : true, "METADATA_ID" : "2YPZPS-HXTS-RWNF-VYEVDD", "SIGNATURE" : "MEYCIQDOjqH0Z87GgDhJFNYqvB5n8Vp5CCAZW5deuHWG7OW/lQIhAKni0PmEj9Fb/2lx+kzSu8Pdi8v8J13ozIvh0L3ehIkI" }
