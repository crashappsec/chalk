#!/usr/bin/env bash

set -euo pipefail

inspect() {
    for arg; do
        docker buildx imagetools inspect --raw "$arg" 2> /dev/null && break
    done
}
sha256() {
    sha256sum | awk '{print $1}'
}
hash() {
    cat | cut -d: -f2
}

show_image=
show_digest=
show_attestations=
show_attestation=
show_layer=
show_dsse=
show_statement=
cosign=cosign
verify=

for arg; do
    shift
    case "$arg" in
        --image)
            show_image=true
            ;;
        --digest)
            show_digest=true
            ;;
        --attestations)
            show_attestations=true
            ;;
        --attestation)
            show_attestation=true
            ;;
        --layer)
            show_layer=true
            ;;
        --dsse)
            show_dsse=true
            ;;
        --statement)
            show_statement=true
            ;;
        --all)
            show_image=true
            show_digest=true
            show_attestations=true
            show_attestation=true
            show_layer=true
            show_dsse=true
            show_statement=true
            ;;
        --cosign=*)
            cosign=${arg##*=}
            ;;
        --verify)
            verify=true
            ;;
        *)
            set -- "$@" "$arg"
            ;;
    esac
done

tag=$1
name=$(echo "$tag" | cut -d: -f1-2)

if [ -n "$show_image" ]; then
    echo "IMAGE" > /dev/stderr
    inspect "$tag" | jq
fi

platform_query=".manifests[] | select(.platform.os == \"linux\").digest"
if inspect "$tag" | jq -e -r "$platform_query" &> /dev/null; then
    digest=$(inspect "$tag" | jq -r "$platform_query" | hash)
else
    digest=$(inspect "$tag" | sha256)
fi

if [ -n "$show_digest" ]; then
    echo "DIGEST" > /dev/stderr
    echo "$digest"
fi

attestation=$(inspect "$name:sha256-$digest" "$name:sha256-$digest.att")
list_query=".manifests[-1].digest"
if echo "$attestation" | jq -e -r "$list_query" &> /dev/null; then
    if [ -n "$show_attestations" ]; then
        echo "ATTESTATIONS" > /dev/stderr
        echo "$attestation" | jq
    fi
    att_digest=$(echo "$attestation" | jq -r "$list_query")
    attestation=$(inspect "$name@$att_digest")
fi
if [ -n "$show_attestation" ]; then
    echo "ATTESTATION" > /dev/stderr
    echo "$attestation" | jq
fi

layer_digest=$(echo "$attestation" | jq -r '.layers[0].digest')
layer=$(inspect "$name@$layer_digest")
if [ -n "$show_layer" ]; then
    echo "LAYER" > /dev/stderr
    echo "$layer" | jq
fi

dsse=$(echo "$layer" | jq '.dsseEnvelope // .')
if [ -n "$show_dsse" ]; then
    echo "DSSE" > /dev/stderr
    echo "$dsse" | jq
fi

if [ -n "$show_statement" ]; then
    statement=$(echo "$dsse" | jq -r '.payload' | base64 -d)
    echo "STATEMENT" > /dev/stderr
    echo "$statement" | jq
    if echo "$statement" | jq -e '.predicate.Data' &> /dev/null; then
        echo "STATEMENT" > /dev/stderr
        echo "$statement" | jq -r '.predicate.Data' | jq
        echo "CHALK" > /dev/stderr
        echo "$statement" | jq -r '.predicate.Data' | jq -r '.predicate.attributes[0].evidence' | jq
    fi
fi

to_sign() {
    payload_type=$(echo "$dsse" | jq -r '.payloadType')
    payload=$(echo "$dsse" | jq -r '.payload' | base64 -d)
    printf "DSSEv1 %d %s %d %s" \
        "${#payload_type}" \
        "$payload_type" \
        "${#payload}" \
        "$payload" \
        | tee >(
            cat > /dev/stderr
            echo > /dev/stderr
        )
}

cosign() {
    set -x
    command $cosign "$@"
}

if [ -n "$verify" ]; then
    to_sign \
        | COSIGN_PASSWORD=$CHALK_PASSWORD \
            cosign \
            verify-blob \
            --key=chalk.pub \
            --insecure-ignore-tlog=true \
            --insecure-ignore-sct=true \
            --signature="$(echo "$dsse" | jq -r '.signatures[0].sig')" \
            -
fi
