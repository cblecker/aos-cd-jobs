#!/bin/bash
set -o xtrace

MB_PATH=$(readlink -f $0)
SCRIPTS_DIR=$(dirname $MB_PATH)

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace


function get_version_fields {
    COUNT="$1"

    if [ "$COUNT" == "" ]; then
        echo "Invalid number of Version fields specified: $COUNT"
        return 1
    fi

    V="$(grep Version: openshift-scripts.spec | awk '{print $2}')"
    # e.g. "3.6.126" => "3 6 126" => wc + awk gives number of independent fields
    export CURRENT_COUNT="$(echo ${V} | tr . ' ' | wc | awk '{print $2}')"

    # If there are more fields than we expect, something has gone wrong and needs human attention.
    if [ "$CURRENT_COUNT" -gt "$COUNT" ]; then
        echo "Unexpected number of fields in current version: $CURRENT_COUNT ; expected less-than-or-equal to $COUNT"
        return 1
    fi

    if [ "$CURRENT_COUNT" -lt "$COUNT" ]; then
        echo -n "${V}"
        while [ "$CURRENT_COUNT" -lt "$COUNT" ]; do
            echo -n ".0"
            CURRENT_COUNT=$(($CURRENT_COUNT + 1))
        done
    else
        # Extract the value of the last field
        MINOREST_FIELD="$(echo -n ${V} | rev | cut -d . -f 1 | rev)"
        NEW_MINOREST_FIELD=$(($MINOREST_FIELD + 1))
        # Cut off the minorest version of the version and append the newly calculated patch version
        echo -n "$(echo ${V} | rev | cut -d . -f 1 --complement | rev).$NEW_MINOREST_FIELD"
    fi
}


# Use the directory relative to this Jenkins job.
BUILDPATH="${WORKSPACE}/go"
mkdir -p $BUILDPATH
cd $BUILDPATH
export GOPATH="$( pwd )"
WORKPATH="${BUILDPATH}/src/github.com/openshift/"
mkdir -p $WORKPATH
echo "GOPATH: ${GOPATH}"
echo "BUILDPATH: ${BUILDPATH}"
echo "WORKPATH ${WORKPATH}"

# Old OS1 buildvm keytab
#kinit -k -t /home/jenkins/ocp-build.keytab ocp-build/atomic-e2e-jenkins.rhev-ci-vms.eng.rdu2.redhat.com@REDHAT.COM
kinit -k -t /home/jenkins/ocp-build-buildvm.openshift.eng.bos.redhat.com.keytab ocp-build/buildvm.openshift.eng.bos.redhat.com@REDHAT.COM

# This variable set by the Jenkins pipeline.
if [ -z "$RELEASE_VERSION" ]; then
    echo "Release version has not been set"
    exit 1
fi

# Incoming into this script is $RELEASE_VERSION which will be something like "3.2.0".
# Gather the first two fields; "3.2.0" -> "3.2"
MAJOR_MINOR_VERSION="$(echo "${RELEASE_VERSION}." | cut -d . -f 1-2)"

rm -rf online
git clone git@github.com:openshift/online.git
cd online/

if [ "${BUILD_MODE}" == "online:int" ] ; then
    SPEC_VERSION_COUNT=4
elif [ "${BUILD_MODE}" == "online:stg" ] ; then
    git checkout -q stage
    FORCE_REBUILD="true"
    SPEC_VERSION_COUNT=5
elif [ "${BUILD_MODE}" == "pre-release" ] ; then
    # pre-release assumes content is coming from master branch
    SPEC_VERSION_COUNT=6
elif [ "${BUILD_MODE}" == "release" ] ; then
    git checkout -q "online-${RELEASE_VERSION}"
    FORCE_REBUILD="true"
    SPEC_VERSION_COUNT=6
fi

echo
echo "=========="
echo "Setup OIT stuff"
echo "=========="

OIT_DIR="${BUILDPATH}/enterprise-images/"
rm -rf ${OIT_DIR}
mkdir -p ${OIT_DIR}
OIT_PATH="${OIT_DIR}/oit/oit.py"
git clone git@github.com:openshift/enterprise-images.git ${OIT_DIR}

# Check to see if there have been any changes since the last tag
if git describe --abbrev=0 --tags --exact-match HEAD >/dev/null 2>&1 && [ "${FORCE_REBUILD}" != "true" ] ; then
    echo ; echo "No changes since last tagged build"
    echo "No need to build anything. Stopping."
else

    # Feeds into ose.conf in order to target correct Dockerfiles
    ONLINE_DOCKERFILE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    export ONLINE_DOCKERFILE_BRANCH

    VOUT="$(get_version_fields ${SPEC_VERSION_COUNT})"
    if [ "$?" != "0" ]; then
      echo "Error determining version fields: $VOUT"
      exit 1
    fi

    export TITO_USE_VERSION="--use-version=$VOUT"

    #There have been changes, so rebuild
    echo
    echo "=========="
    echo "Tito Tagging"
    echo "=========="
    tito tag --accept-auto-changelog "${TITO_USE_VERSION}"
    export VERSION="$(grep Version: openshift-scripts.spec | awk '{print $2}')"

    git push
    git push --tags

    echo
    echo "=========="
    echo "Tito building in brew"
    echo "=========="
    TASK_NUMBER=`tito release --yes --test brew | grep 'Created task:' | awk '{print $3}'`
    echo "TASK NUMBER: ${TASK_NUMBER}"
    echo "TASK URL: https://brewweb.engineering.redhat.com/brew/taskinfo?taskID=${TASK_NUMBER}"
    echo
    brew watch-task ${TASK_NUMBER}

    # The build target tags things as libra-rhel-7-test. We need to tag as -candidate
    # for the rest of out logic to work.
    TAG=`git describe --abbrev=0`
    COMMIT=`git log -n 1 --pretty=%h`
    brew tag-pkg libra-rhel-7-candidate ${TAG}.git.0.${COMMIT}.el7

    # tag-pkg seems to work async even though we are not specifying the --nowait argument.
    # We have seen the push which follows push the old build instead of the new, so
    # using a sleep below to allow brew to get into a consistent state.
    sleep 20

    echo
    echo "=========="
    echo "Signing RPMs"
    echo "=========="
    "${WORKSPACE}/build-scripts/sign_rpms.sh" "libra-rhel-7-candidate" "openshifthosted"

    pushd "${WORKSPACE}"
    COMMIT_SHA="$(git rev-parse HEAD)"
    popd
    PUDDLE_CONF_BASE="https://raw.githubusercontent.com/openshift/aos-cd-jobs/${COMMIT_SHA}/build-scripts/puddle-conf"
    PUDDLE_CONF="${PUDDLE_CONF_BASE}/atomic_openshift_online-${MAJOR_MINOR_VERSION}.conf"
    PUDDLE_SIG_KEY="b906ba72"

    echo
    echo "=========="
    echo "Building Puddle"
    echo "=========="
    ssh ocp-build@rcm-guest.app.eng.bos.redhat.com \
        sh -s -- --conf "${PUDDLE_CONF}" --keys "${PUDDLE_SIG_KEY}" -b -d -n -s --label=building \
        < "${WORKSPACE}/build-scripts/rcm-guest/call_puddle.sh"

    echo
    echo "=========="
    echo "Update Dockerfiles"
    echo "=========="ild
    ${OIT_PATH} --user=ocp-build --metadata-dir ${OIT_DIR} --working-dir ${OIT_WORKING} --group oso-${RELEASE_VERSION} \
    images:rebase --version v${VERSION} \
    --release 1 \
    --message "MaxFileSize: 52428800" --push

    echo
    echo "=========="
    echo "Build Images"
    echo "=========="
    ${OIT_PATH} --user=ocp-build --metadata-dir ${OIT_DIR} --working-dir ${OIT_WORKING} --group oso-${RELEASE_VERSION} \
    images:build \
    --push-to-defaults --repo-type unsigned

    echo
    echo "=========="
    echo "Create latest puddle"
    echo "=========="
    ssh ocp-build@rcm-guest.app.eng.bos.redhat.com \
        sh -s -- --conf "${PUDDLE_CONF}" --keys "${PUDDLE_SIG_KEY}" -b -d -n \
        < "${WORKSPACE}/build-scripts/rcm-guest/call_puddle.sh"

    echo
    echo "=========="
    echo "Build and Push repos"
    echo "=========="
    ssh ocp-build@rcm-guest.app.eng.bos.redhat.com \
      sh -s "${VERSION}" "${BUILD_MODE}" \
      < "${WORKSPACE}/build-scripts/rcm-guest/push-openshift-online-to-mirrors.sh"

fi

echo
echo "=========="
echo "Finished OpenShift scripts"
echo "=========="
