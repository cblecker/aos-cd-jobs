node() {
    checkout scm
    def buildlib = load("pipeline-scripts/buildlib.groovy")
    def commonlib = buildlib.commonlib
    def slacklib = commonlib.slacklib

    properties(
        [
            disableConcurrentBuilds(),
            [
                $class : 'ParametersDefinitionProperty',
                parameterDefinitions: [
                    commonlib.ocpVersionParam('BUILD_VERSION'),
                    booleanParam(
                        name: 'SEND_TO_RELEASE_CHANNEL',
                        defaultValue: true,
                        description: "If true, send output to #art-release-4-<version>"
                    ),
                    booleanParam(
                        name: 'SEND_TO_AOS_ART',
                        defaultValue: false,
                        description: "If true, send notification to #aos-art"
                    ),
                    commonlib.mockParam(),
                ]
            ],
        ]
    )

    commonlib.checkMock()

    GITHUB_BASE = "git@github.com:openshift" // buildlib uses this global var

    // doozer_working must be in WORKSPACE in order to have artifacts archived
    def doozer_working = "${WORKSPACE}/doozer_working"
    buildlib.cleanWorkdir(doozer_working)

    // Run pyartcd
    sh "mkdir -p ./artcd_working"

    def cmd = [
        "artcd",
        "-vv",
        "--working-dir=./artcd_working",
        "--config=./config/artcd.toml",
        "images-health",
        "--version=${params.BUILD_VERSION}"
    ]
    if (params.SEND_TO_RELEASE_CHANNEL) {
        cmd << "--send-to-release-channel"
    }
    if (params.SEND_TO_AOS_ART) {
        cmd << "--send-to-aos-art"
    }

    withCredentials([string(credentialsId: 'art-bot-slack-token', variable: 'SLACK_BOT_TOKEN'), string(credentialsId: 'openshift-bot-token', variable: 'GITHUB_TOKEN')]) {
        withEnv(["BUILD_USER_EMAIL=${env.BUILD_USER_EMAIL}"]) {
            try {
                echo "Will run ${cmd}"
                commonlib.shell(script: cmd.join(' '))
            } catch (exception) {
                slacklib.to(BUILD_VERSION).say(":alert: Image health check job failed!\n${BUILD_URL}")
                currentBuild.result = "FAILURE"
                throw exception  // gets us a stack trace FWIW
            }
        }
    }
}
