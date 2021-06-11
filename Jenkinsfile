#!/usr/bin/env groovy

node {
    checkout scm
    def joblib = load("build.groovy")
    def commonlib = joblib.commonlib
    def slacklib = commonlib.slacklib

    commonlib.describeJob("ocp4", """
        <h2>Build OCP 4.y components incrementally</h2>
        <b>Timing</b>: Usually run automatically from merge_ocp.
        Humans may run as needed. Locks prevent conflicts.

        In typical usage, scans for changes that could affect package or image
        builds and rebuilds the affected components.  Creates new plashets if
        the automation is not frozen or if there are RPMs that are built in this run,
        and runs other jobs to sync builds to nightlies, create
        operator metadata, and sweep bugs and builds into advisories.

        May also build unconditionally or with limited components.
    """)


    // Expose properties for a parameterized build
    properties(
        [
            disableResume(),
            buildDiscarder(
                logRotator(
                    artifactDaysToKeepStr: '365',
                    daysToKeepStr: '365')),
            [
                $class: 'ParametersDefinitionProperty',
                parameterDefinitions: [
                    commonlib.dryrunParam(),
                    commonlib.mockParam(),
                    commonlib.doozerParam(),
                    commonlib.ocpVersionParam('BUILD_VERSION', '4'),
                    string(
                        name: 'NEW_VERSION',
                        description: '(Optional) version for build instead of most recent\nor "+" to bump most recent version',
                        defaultValue: "",
                        trim: true,
                    ),
                    string(
                        name: 'ASSEMBLY',
                        description: 'The name of an assembly to rebase & build for. If assemblies are not enabled in group.yml, this parameter will be ignored',
                        defaultValue: "stream",
                        trim: true,
                    ),
                    booleanParam(
                        name: 'FORCE_BUILD',
                        description: 'Build regardless of whether source has changed',
                        defaultValue: false,
                    ),
                    booleanParam(
                        name: 'FORCE_MIRROR_STREAMS',
                        description: 'Ensure images:mirror-streams runs after this build, even if it is a small batch',
                        defaultValue: false,
                    ),
                    choice(
                        name: 'BUILD_RPMS',
                        description: 'Which RPMs are candidates for building? "only/except" refer to list below',
                        choices: [
                            "all",
                            "only",
                            "except",
                            "none",
                        ].join("\n"),
                    ),
                    string(
                        name: 'RPM_LIST',
                        description: '(Optional) Comma/space-separated list to include/exclude per BUILD_RPMS (e.g. openshift,openshift-kuryr)',
                        defaultValue: "",
                        trim: true,
                    ),
                    choice(
                        name: 'BUILD_IMAGES',
                        description: 'Which images are candidates for building? "only/except" refer to list below',
                        choices: [
                            "all",
                            "only",
                            "except",
                            "none",
                        ].join("\n"),
                    ),
                    string(
                        name: 'IMAGE_LIST',
                        description: '(Optional) Comma/space-separated list to include/exclude per BUILD_IMAGES (e.g. logging-kibana5,openshift-jenkins-2)',
                        defaultValue: "",
                        trim: true,
                    ),
                    commonlib.suppressEmailParam(),
                    string(
                        name: 'MAIL_LIST_SUCCESS',
                        description: '(Optional) Success Mailing List\naos-cicd@redhat.com,aos-qe@redhat.com',
                        defaultValue: "",
                        trim: true,
                    ),
                    string(
                        name: 'MAIL_LIST_FAILURE',
                        description: 'Failure Mailing List',
                        defaultValue: [
                            'aos-art-automation+failed-ocp4-build@redhat.com'
                        ].join(','),
                        trim: true
                    ),
                    string(
                        name: 'SPECIAL_NOTES',
                        description: '(Optional) special notes to include in the build email',
                        defaultValue: "",
                        trim: true,
                    ),
                ]
            ],
        ]
    )

    commonlib.checkMock()

    currentBuild.description = ""
    try {

        sshagent(["openshift-bot"]) {
            // To work on private repos, buildlib operations must run
            // with the permissions of openshift-bot

            lock("github-activity-lock-${params.BUILD_VERSION}") {
                stage("initialize") { joblib.initialize() }
                buildlib.assertBuildPermitted(doozerOpts)
                try {
                    stage("build RPMs") {
                        joblib.stageBuildRpms()
                    }
                } catch (err) {
                    currentBuild.result = 'FAILURE'
                }

                // if the automation is not frozen perform compose
                // otherwise if automation is frozen but there
                // are rpms in the build plan perform compose
                // and announce on slack

                if(buildlib.getAutomationState(doozerOpts) in ["no", "False"]){
                    lock("compose-lock-${params.BUILD_VERSION}") {
                        stage("build compose") { joblib.stageBuildCompose() }
                    }
                } else if(joblib.buildPlan.buildRpms){
                    lock("compose-lock-${params.BUILD_VERSION}") {
                        stage("build compose") {
                            joblib.stageBuildCompose()
                            slacklib.to(commonlib.extractMajorMinorVersion(params.BUILD_VERSION)).say("""
                                *:alert: ocp4 build compose ran during automation freeze*
                                 There were RPMs in the build plan that forced build compose during automation freeze.
                            """)
                        }
                    }
                } else {
                    // a no-op stage, mainly so the jenkins stage display looks right (static stages between runs).
                    stage("build compose") { echo "No RPM compose required." }
                }

                // Since plashets may have been rebuild, fire off sync for CI. TODO: Run for other arches
                // if CI ever requires them.
                /* 
                // Disabled because it increases 404s from mirror. sync-for-ci completely replaces content, so if
                // yum is retrieving content while the mirror is being updated, yum can error out. This is 
                // exascerbated by a 1 minute caching effect in the rpm mirroring pods in CI for repo manifest 
                // data: https://github.com/openshift/content-mirror/pull/1#discussion_r581380438 . We need to
                // find a way to stack these files so that the caching effect does not result in 404s.
                build(
                    job: '/aos-cd-builds/build%2Fsync-for-ci', 
                    propagate: false,
                    wait: false,
                    parameters: [
                        string(name: 'GROUP', value: "openshift-${params.BUILD_VERSION}"),
                        string(name: 'REPOSYNC_DIR', value: "${params.BUILD_VERSION}"),
                        string(name: 'ARCH', value: "x86_64"),
                    ],
                )*/
                

                stage("update dist-git") { joblib.stageUpdateDistgit() }
                stage("build images") { joblib.stageBuildImages() }
            }
            lock("mirroring-rpms-lock-${params.BUILD_VERSION}") {
                stage("mirror RPMs") { joblib.stageMirrorRpms() }
            }
            if (!buildlib.allImagebuildfailed){
                stage("sync images") { joblib.stageSyncImages() }
                stage("push qe quay images") { joblib.stagePushQEImages() }
                stage("sweep") {
                    buildlib.sweep(params.BUILD_VERSION)
                }
            }
        }
        stage("report success") { joblib.stageReportSuccess() }
    } catch (err) {

        if (!buildlib.isBuildPermitted(doozerOpts)) {
            echo 'Exiting because this build is not permitted: ${err}'
            return
        }

        if (params.MAIL_LIST_FAILURE.trim()) {
            commonlib.email(
                to: params.MAIL_LIST_FAILURE,
                from: "aos-team-art@redhat.com",
                subject: "Error building OCP ${params.BUILD_VERSION}",
                body:
"""\
Pipeline build "${currentBuild.displayName}" encountered an error:
${currentBuild.description}


View the build artifacts and console output on Jenkins:
    - Jenkins job: ${commonlib.buildURL()}
    - Console output: ${commonlib.buildURL('console')}

"""

            )
        }
        currentBuild.description += "<hr />${err}"
        currentBuild.result = "FAILURE"
        throw err  // gets us a stack trace FWIW
    } finally {
        commonlib.compressBrewLogs()
        commonlib.safeArchiveArtifacts([
            "doozer_working/*.log",
            "doozer_working/brew-logs.tar.bz2",
            "doozer_working/*.yaml",
            "doozer_working/*.yml",
        ])
        buildlib.cleanWorkdir(joblib.doozerWorking)
        buildlib.cleanWorkspace()
    }
}
