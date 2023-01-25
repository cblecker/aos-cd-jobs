#!/usr/bin/env groovy
node {
    checkout scm
    commonlib = load("pipeline-scripts/commonlib.groovy")
    commonlib.describeJob("aws-iso-marketplace-quay-image-builder", """
        --------------------------
        Constructs an AMI for a fully disconnected and self-contained install.
        --------------------------
        https://issues.redhat.com/browse/ART-5431
    """)
}

pipeline {
    agent any
    options {
        disableConcurrentBuilds()
        disableResume()
        buildDiscarder(
          logRotator(
            artifactDaysToKeepStr: '60',
            daysToKeepStr: '60')
        )
    }

    parameters {
        string(
            name: "CINCINNATI_OCP_VERSION",
            description: "A version of OpenShift in the candidate channel from which to create an AMI (e.g. 4.10.36).",
            defaultValue: "",
            trim: true,
        )
        string(
            name: "QUAY_IMAGE_BUILDER_COMMITISH",
            description: "A commitish to use for github.com/openshift/quay-image-builder",
            defaultValue: "master",
            trim: true,
        )
        booleanParam(
            name: 'BUILD_RUNNER_IMAGE',
            value: false,
            description: "The builder is run in a docker container. Select true to spend time building/rebuilding this image."
        )
        booleanParam(
            name: 'BUILD_TEMPLATE_AMI',
            value: false,
            description: "The template AMI construct that speeds up the creation of the final deliverable. It installs packages and configures hundreds of elements of the system so that the final image build process does not need to. It should only need to be updated if the template changes or packages are taking a long time to be updated in final AMI builds."
        )
        booleanParam(name: 'MOCK', value: params.MOCK)
    }

    stages {
        stage("Validate Params") {
            steps {
                script {
                    if (!params.CINCINNATI_OCP_VERSION) {
                        error "CINCINNATI_OCP_VERSION must be specified"
                    }
                }
            }
        }

        stage("Wait for Cincy") {
            steps {
                // Before quay-image-builder can work, the release must be present in Cincinnati.
                (major, minor) = commonlib.extractMajorMinorVersionNumbers(params.CINCINNATI_OCP_VERSION)

                // Everything starts here, so it is our early chance to find a release.
                channel = "candidate-${major}.${minor}"
                attempt = 0
                retry(60) {
                    if (attempt > 0) {
                        echo "Waiting for up to 1 hour for version"
                        sleep(unit: "MINUTES", time: 1)
                    }
                    // This will throw an exception if the desired version is not in Cincinnati.
                    sh("""
                    curl -sH 'Accept:application/json' 'https://api.openshift.com/api/upgrades_info/v1/graph?channel=${channel}' | jq .nodes | grep '"${params.CINCINNATI_OCP_VERSION}"'
                    """)
                    attempt++
                }
            }
        }

        stage("Clone Builder") {
            steps {
                script {
                    sh """
                    rm -rf quay-image-builder
                    git clone https://github.com/openshift/quay-image-builder
                    cd quay-image-builder
                    git checkout ${params.QUAY_IMAGE_BUILDER_COMMITISH}
                    """
                }
            }
        }

        stage("Runner Image") {
            steps {
                script {
                    if (params.BUILD_RUNNER_IMAGE) {
                        commonlib.shell("sudo podman build . -f runner-image.Dockerfile -t runner-image")
                    } else {
                        echo "Skipping the build or rebuild of the runner-image"
                    }
                }
            }
        }

        stage("Build Template AMI") {
            steps {
                script {
                    if (params.BUILD_TEMPLATE_AMI) {
                        // Establish the credentials necessary to build the AMI in osd-art / us-east-2 region.
                        withCredentials([aws(credentialsId: 'quay-image-builder-aws', accessKeyVariable: 'AWS_ACCESS_KEY_ID', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY')]) {
                            dir("quay-image-builder") {
                                commonlib.shell("""
                                    # For this AMI, we do not want to carry any optional operators. Strip the optional
                                    # operators from the template.
                                    cat imageset-config.yaml | yq '.mirror.operators=[]' > generated-imageset-config-template.yaml
                                    # See https://github.com/openshift/quay-image-builder for environment variable description.
                                    podman run --rm -v $PWD:/quay-image-builder:z -e EIP_ALLOC=eipalloc-03243b75c8ef5f56b -e IAM_INSTANCE_PROFILE=ec2-instance-profile-for-quay-image-builder -e IMAGESET_CONFIG_TEMPLATE=/quay-image-builder/generated-imageset-config-template.yaml -e OCP_VER=${params.CINCINNATI_OCP_VERSION} -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION=us-east-2 -v $HOME/.docker/:/pullsecret:z -e PULL_SECRET=/pullsecret/config.json --entrypoint /quay-image-builder/build_template.sh runner-image
                                """)
                            }
                        }
                    } else {
                        echo "Skipping the template AMI build"
                    }
                }
            }
        }

        stage("Run Build") {
            steps {
                script {
                    // Establish the credentials necessary to build the AMI in osd-art / us-east-2 region.
                    withCredentials([aws(credentialsId: 'quay-image-builder-aws', accessKeyVariable: 'AWS_ACCESS_KEY_ID', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'), string(credentialsId: 'ICMP_AWS_SHARE_ACCOUNT', variable: 'SHARE_ACCOUNT')]) {
                        dir("quay-image-builder") {
                            commonlib.shell("""
                                # For this AMI, we do not want to carry any optional operators. Strip the optional
                                # operators from the template.
                                cat imageset-config.yaml | yq '.mirror.operators=[]' > generated-imageset-config-template.yaml
                                # See https://github.com/openshift/quay-image-builder for environment variable description.
                                podman run --rm -v $PWD:/quay-image-builder:z -e EIP_ALLOC=eipalloc-03243b75c8ef5f56b -e IAM_INSTANCE_PROFILE=ec2-instance-profile-for-quay-image-builder -e IMAGESET_CONFIG_TEMPLATE=/quay-image-builder/generated-imageset-config-template.yaml -e OCP_VER=${params.CINCINNATI_OCP_VERSION} -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION=us-east-2 -v $HOME/.docker/:/pullsecret:z -e PULL_SECRET=/pullsecret/config.json --entrypoint /quay-image-builder/build.sh runner-image
                            """)
                            // Packer, involved by build.sh, will create a machine-readable packer.log. Look
                            // for a line like:
                            // 1674670955,amazon-ebs,artifact,0,id,us-east-2:ami-xxxxxxxxxxxxxxxxx
                            ami_info = sh(returnStdout: true, script: "cat packer.log | awk -F, '$0 ~/artifact,0,id/ {print $6}'").trim() // should look like us-east-2:ami-xxxxxxxxxxxxxxxxx
                            (region, ami_id) = ami_info.split(':')

                            // Share with staging account https://issues.redhat.com/browse/ART-5510
                            commonlib.shell("""
                            aws ec2 modify-image-attribute --image-id ${ami_id} --launch-permission "Add=[{UserId=${ICMP_AWS_SHARE_ACCOUNT}}]"
                            """)
                        }
                    }
                }
            }
        }
    }
}

