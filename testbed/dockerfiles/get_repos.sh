#!/usr/bin/env bash 

# download top 100 repos 
if ! [ -f top100_forked.txt ]; then
    python3 fetch.py
fi

# create a directory to fork them in
mkdir -p repos
mkdir -p results
# clone them
for repo in `cat top100_forked.txt`; do
    repo_name="${repo##*/}"
    OUTDIR=results/"${repo_name}"
    mkdir -p ${OUTDIR}
    ERRFILE=${OUTDIR}/cmd.err
    if ! [ -d "repos/${repo_name}" ]; then 
        git clone --depth=1 "${repo}" "repos/${repo_name}" 
    fi
    
    echo "==============Processing ${repo}"

    
    pushd "repos/${repo_name}" 
        RESULTS_PREFIX=../../
        rm -f chalk-*.tmp virtual-chalk.json
        if ! [ -f Dockerfile ]; then
            echo "No dockerfile in ${repo_name}" > ${RESULTS_PREFIX}/${ERRFILE}
            echo "No dockerfile in ${repo_name} root. Skipping"
            continue
        fi
        chalk --debug --log-level=warn -C docker build --platform=linux/amd64 . 1>${RESULTS_PREFIX}/${OUTDIR}/__chalk.build 2>&1
        IMAGE_INFO=$(cat ${RESULTS_PREFIX}/${OUTDIR}/__chalk.build | grep "writing image sha256" | cut -d':' -f2 | cut -d' ' -f1 | tail -n1)
        docker inspect $IMAGE_INFO > ${RESULTS_PREFIX}/${OUTDIR}/__docker_inspect.json 2>${RESULTS_PREFIX}/${ERRFILE}
        COMMIT_ID=`git log | grep commit | cut -d' ' -f2`
        TMP_DOCKERFILE=`grep "/chalk.json" chalk-* | cut -d':' -f1`     
        CHALK_JSON=`grep "/chalk.json" chalk-* | cut -d' ' -f2`
        mv chalk-*.tmp ${RESULTS_PREFIX}/${OUTDIR} 2> ${RESULTS_PREFIX}/${ERRFILE}
        mv virtual-chalk.json ${RESULTS_PREFIX}/${OUTDIR} 2> ${RESULTS_PREFIX}/${ERRFILE}
        # cleanup docker
        docker rm $IMAGE_INFO 2> ${RESULTS_PREFIX}/${ERRFILE}
    popd 

    CODEOWNERS=`find "repos/${repo_name}" -name "CODEOWNERS"`
    params=$(cat <<EOF
{
    "REPO_PATH": "${repo_name}",
    "COMMIT_ID": "${COMMIT_ID}",
    "TMP_DOCKERFILE": "${repo_name}/${TMP_DOCKERFILE}",
    "CHALK_JSON": "${repo_name}/${CHALK_JSON}",
    "IMAGES_BUILT": "${IMAGE_INFO}",
    "CODEOWNERS": "${CODEOWNERS}"
}
EOF
)

    echo ${params} > ${OUTDIR}/__params.json
done
