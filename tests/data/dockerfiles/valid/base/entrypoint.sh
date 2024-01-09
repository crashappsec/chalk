#!/bin/sh

if [ "$#" -ne 1 ]; then
    echo "Wrong number of arguments"
    exit 1
fi

arg=$1
if [ "$arg" = "true" ]; then
    echo "Args are correct"
    exit 0
fi

echo "Args are wrong. Expect one true arg"
exit 1
