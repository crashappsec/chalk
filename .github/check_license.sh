#!/bin/sh

set -e

args=
for arg; do
    shift
    case "$arg" in
        --)
            break
            ;;
        *)
            args="$args $arg"
            ;;
    esac
done

for file; do
    years=$(git log --follow --oneline --format='%aI' -- "$file" | cut -d- -f1 | tail -n1)
    last=$(git log --follow --oneline --format='%aI' -- "$file" | cut -d- -f1 | head -n1)
    if [ "$years" = "2022" ]; then
        years=2023
    fi
    if [ "$last" != "$years" ]; then
        years="$years-$last"
    fi
    if [ -z "$years" ]; then
        years=$(date +%Y)
    fi
    licenseheaders --years="$years" $args "$file"
done
