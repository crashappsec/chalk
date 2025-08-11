#!/bin/sh

set -e

for file; do
    if grep 'added by chalk' "$file"; then
        # remove all lines after the match
        sed '/added by chalk/,$d' -i "$file"
        sed -z 's/\n*$/\n/' -i "$file"
    fi
done
