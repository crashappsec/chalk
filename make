#!/usr/bin/env bash

set -eEu
set -o pipefail

# small make wrapper for allowing to call make with additional
# arguments which is very useful for things like running specific tests
# but still allowing to define recipy for running tests in the Makefile
#
# these then become equivalent
# make foo args="bar baz --flag"
# ./make.sh foo bar baz --flag
#
# more context at
# https://stackoverflow.com/questions/2214575/passing-arguments-to-make-run

# in case this script is already on PATH
# fallback to next make in PATH
make="make"
current_script=$(realpath $0)
if [ "$(which make)" = "$current_script" ]; then
    make=$(which -a make | grep -v $current_script | head -n1)
fi

target=${1:-}
[ $# -gt 0 ] && shift

case $target in
    -*)
        # if target starts with - then call make as-is
        exec $make $target $@
        ;;
    *)
        export args=$(echo $@ | sed "s#$target/##")
        exec $make $target
        ;;
esac
