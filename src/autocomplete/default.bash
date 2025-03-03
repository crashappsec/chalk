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

function _chalk_complete {
    COMPREPLY=($(compgen -W "$@" -- "${_CHALK_CUR_WORD}"))
}

function _chalk_toplevel_completions {
    case ${COMP_WORDS[${_CHALK_CUR_IX}]} in
        insert)
            _chalk_shift_one
            _chalk_complete "
                $(_chalk_flags)
                --recursive
                --no-recursive
                --mark-template
                --report-template
                "
            _chalk_filedir
            ;;
        extract)
            _chalk_shift_one
            _chalk_complete "
                $(_chalk_flags)
                --recursive
                --no-recursive
                --report-template
                --search-layers
                --no-search-layers
                images
                containers
                all
                "
            _chalk_filedir
            ;;
        delete)
            _chalk_shift_one
            _chalk_complete "
                $(_chalk_flags)
                --recursive
                --no-recursive
                --report-template
                "
            _chalk_filedir
            ;;
        exec)
            _chalk_shift_one
            case ${_CHALK_PREV} in
                "--exec-command-name")
                    _chalk_command
                    ;;
                "--") ;;
                *)
                    _chalk_complete "
                    --
                    $(_chalk_flags)
                    --exec-command-name
                    --chalk-as-parent
                    --no-chalk-as-parent
                    --heartbeat
                    --no-heartbeat
                    --report-template
                    "
                    ;;
            esac
            ;;
        dump)
            _chalk_shift_one
            _chalk_complete "
                $(_chalk_flags)
                params
                cache
                all
                "
            ;;
        load)
            _chalk_shift_one
            _chalk_complete "
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
                "
            _chalk_filedir
            ;;
        docker)
            _chalk_shift_one
            _chalk_command_offset 1
            ;;
        env) ;&
        environment) ;&
        setup) ;&
        version)
            _chalk_shift_one
            _chalk_complete "$(_chalk_flags)"
            ;;
        help)
            _chalk_shift_one
            _chalk_complete "
                builtins
                commands
                conf
                conffile
                config
                configs
                configurations
                delete
                docker
                dump
                env
                exec
                extract
                insert
                keys
                load
                metadata
                output
                plugins
                reporting
                reports
                search
                setup
                templates
                topics
                version
                "
            ;;
        *)
            if [[ $_CHALK_CUR_IX -le $COMP_CWORD ]]; then
                _chalk_shift_one
                _chalk_toplevel_completions
            else
                _chalk_complete "
                  $(_chalk_flags)
                   config
                   delete
                   docker
                   dump
                   env
                   exec
                   extract
                   help
                   insert
                   load
                   setup
                   version
                   "
            fi
            ;;
    esac
}

function _chalk_shift_one {
    ((_CHALK_CUR_IX++))
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
