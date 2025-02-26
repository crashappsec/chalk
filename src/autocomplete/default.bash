#!/usr/bin/env bash
##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

# Basic bash completion script. Con4m should start generating these.
# Until then, maintain it manually.

# shellcheck disable=2207

# shims in case these are missing (e.g. on mac zsh)
#
function _chalk_command {
    if type _command &> /dev/null; then
        _command
    fi
}

function _chalk_command_offset {
    if type _command_offset &> /dev/null; then
        # shellcheck disable=2068
        _command_offset $@
    fi
}

function _chalk_filedir {
    if type _filedir &> /dev/null; then
        _filedir
    fi
}

function _chalk_flags {
    # get all flags via:
    # rg '^\s*(command |flag)' src/configs/getopts.c4m
    echo "
        --color
        --no-color
        --help
        --log-level
        --config-file
        --enable-report
        --disable-report
        --report-cache-file
        --time
        --no-time
        --use-embedded-config
        --no-use-embedded-config
        --use-external-config
        --no-use-external-config
        --show-config
        --no-show-config
        --use-report-cache
        --no-use-report-cache
        --debug
        --no-debug
        --skip-command-report
        --no-skip-command-report
        --skip-summary-report
        --no-skip-summary-report
        --skip-summary-report
        --no-skip-summary-report
        --symlink-behavior
        --run-sbom-tools
        --no-run-sbom-tools
        --run-sast-tools
        --no-run-sast-tools
        --virtual
        --no-virtual
        --dry-run
        --no-dry-run
        --wrap
        --no-wrap
        --pager
        --no-pager
    "
}

function _chalk_setup_completions {
    case ${COMP_WORDS[${_CHALK_CUR_IX}]} in
        *)
            COMPREPLY=($(compgen -W "
                $(_chalk_flags)
                --skip-summary-report
                --no-skip-summary-report
                " -- "${_CHALK_CUR_WORD}"))
            ;;
    esac
}

function _chalk_delete_completions {
    if [[ ${_CHALK_CUR_WORD::1} = "-" ]]; then
        COMPREPLY=($(compgen -W "
            $(_chalk_flags)
            --recursive
            --no-recursive
            --report-template
            " -- "${_CHALK_CUR_WORD}"))
    else
        _chalk_filedir
    fi
}

function _chalk_env_completions {
    if [[ ${_CHALK_CUR_WORD::1} = "-" ]]; then
        COMPREPLY=($(compgen -W "
            $(_chalk_flags)
            " -- "${_CHALK_CUR_WORD}"))
    fi
}

function _chalk_version_completions {
    if [[ ${_CHALK_CUR_WORD::1} = "-" ]]; then
        COMPREPLY=($(compgen -W "
            $(_chalk_flags)
            " -- "${_CHALK_CUR_WORD}"))
    fi
}

function _chalk_docker_completions {
    _chalk_command_offset 1
}

function _chalk_load_completions {
    if [[ ${_CHALK_CUR_WORD::1} = "-" ]]; then
        COMPREPLY=($(compgen -W "
            $(_chalk_flags)
            --replace
            --no-replace
            --all
            --no-all
            --params
            --no-params
            --validation
            --no-validation
            --validation-warning
            --no-validation-warning
            " -- "${_CHALK_CUR_WORD}"))
    fi

    if [[ $_CHALK_CUR_IX -le $COMP_CWORD ]]; then
        if [[ ${COMP_WORDS[${_CHALK_CUR_IX}]::1} = "-" ]]; then
            _chalk_shift_one
            _chalk_load_completions
        fi
        # Else, already got a file name so nothing to complete.
    else
        _chalk_filedir
    fi
}

function _chalk_dump_completions {
    if [[ ${_CHALK_CUR_WORD::1} = "-" ]]; then
        COMPREPLY=($(compgen -W "
            $(_chalk_flags)
            " -- "${_CHALK_CUR_WORD}"))
    else
        COMPREPLY+=($(compgen -W "
            params
            cache
            all
        " -- "${_CHALK_CUR_WORD}"))
    fi

    if [[ $_CHALK_CUR_IX -le $COMP_CWORD ]]; then
        if [[ ${COMP_WORDS[${_CHALK_CUR_IX}]::1} = "-" ]]; then
            _chalk_shift_one
            _chalk_load_completions
        fi
        # Else, already got a file name so nothing to complete.
    else
        _chalk_filedir
    fi
}

function _chalk_exec_completions {
    if [[ ${_CHALK_CUR_WORD::1} = "-" ]]; then
        COMPREPLY=($(compgen -W "
            --
            $(_chalk_flags)
            --exec-command-name
            --chalk-as-parent
            --no-chalk-as-parent
            --heartbeat
            --no-heartbeat
            --report-template
            " -- "${_CHALK_CUR_WORD}"))
    else
        if [[ ${_CHALK_PREV} = "--exec-command-name" ]]; then
            _chalk_command
        fi
    fi
}

function _chalk_help_completions {
    COMPREPLY=($(compgen -W "
        metadata
        keys
        search
        templates
        output
        reports
        reporting
        plugins
        insert
        delete
        env
        dump
        load
        config
        version
        docker
        exec
        extract
        setup
        commands
        configurations
        conffile
        configs
        conf
        topics
        builtins
        " -- "${_CHALK_CUR_WORD}"))
}

function _chalk_extract_completions {
    if [[ ${_CHALK_CUR_WORD::1} = "-" ]]; then
        COMPREPLY=($(compgen -W "
            $(_chalk_flags)
            --recursive
            --no-recursive
            --report-template
            --search-layers
            --no-search-layers
            " -- "${_CHALK_CUR_WORD}"))
    else
        _chalk_filedir
        COMPREPLY+=($(compgen -W "
            images
            containers
            all
        " -- "${_CHALK_CUR_WORD}"))
    fi
}

function _chalk_insert_completions {
    if [[ ${_CHALK_CUR_WORD::1} = "-" ]]; then
        COMPREPLY=($(compgen -W "
            $(_chalk_flags)
            --recursive
            --no-recursive
            --mark-template
            --report-template
            " -- "${_CHALK_CUR_WORD}"))
    else
        _chalk_filedir
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
            if [[ $_CHALK_CUR_IX -le $COMP_CWORD ]]; then
                _chalk_shift_one
                _chalk_toplevel_completions
            else
                COMPREPLY=($(compgen -W "
                  $(_chalk_flags)
                   extract
                   insert
                   delete
                   env
                   exec
                   config
                   dump
                   load
                   version
                   docker
                   setup
                   help
                   " -- "${_CHALK_CUR_WORD}"))
            fi
            ;;
    esac
}

function _chalk_shift_one {
    let "_CHALK_CUR_IX++"
}

function _chalk_completions {
    if type _get_comp_words_by_ref &> /dev/null; then
        _get_comp_words_by_ref cur prev words cword
    fi

    _CHALK_CUR_IX=0
    _CHALK_CUR_WORD=${2}
    _CHALK_PREV=${3}

    _chalk_toplevel_completions
}

if type complete &> /dev/null; then
    complete -F _chalk_completions chalk
fi
