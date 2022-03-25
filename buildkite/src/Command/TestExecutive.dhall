let Prelude = ../External/Prelude.dhall

let Command = ./Base.dhall
let Docker = ./Docker/Type.dhall
let Size = ./Size.dhall

let RunInToolchain = ../Command/RunInToolchain.dhall

let Cmd = ../Lib/Cmds.dhall
let SelectFiles = ../Lib/SelectFiles.dhall

let defaultArtifactStep = { name = "GitEnvUpload", key = "upload-git-env", deploy_env_file = "export-git-env-vars.sh" }

in

{
  build = \(duneProfile : Text) ->
    Command.build
      Command.Config::{
        commands =
            -- Build test executive binary
            RunInToolchain.runInToolchainStretch [
              "DUNE_PROFILE=${duneProfile}"
            ] "./buildkite/scripts/build-test-executive.sh"
            
            #
            
            [
              -- Cache test-executive binary
              Cmd.run "artifact-cache-helper.sh test_executive.exe --upload",
              Cmd.run "artifact-cache-helper.sh logproc.exe --upload"
            ],
        label = "Build test-executive",
        key = "build-test-executive",
        target = Size.XLarge,
        if = Some "build.branch != 'develop' && build.branch != 'compatible' && build.branch != 'develop-next'"
      },

  execute = \(testName : Text) -> \(dependsOn : List Command.TaggedKey.Type) ->
    Command.build
      Command.Config::{
        commands =
            [
              -- Download test dependencies
              Cmd.run "artifact-cache-helper.sh test_executive.exe && chmod +x test_executive.exe",
              Cmd.run "artifact-cache-helper.sh logproc.exe && chmod +x logproc.exe",
              Cmd.run (
                  "[ ! -f ${defaultArtifactStep.deploy_env_file} ] && buildkite-agent artifact download --build \\\$BUILDKITE_BUILD_ID " ++
                      "--include-retried-jobs --step _${defaultArtifactStep.name}-${defaultArtifactStep.key} ${defaultArtifactStep.deploy_env_file} ."
              ),

              -- Execute test based on BUILD image
              Cmd.run "MINA_DEB_CODENAME=buster ; source ${defaultArtifactStep.deploy_env_file} && ./buildkite/scripts/run-test-executive.sh ${testName}"
            ],
        artifact_paths = [SelectFiles.exactly "." "${testName}.test.log"],
        label = "${testName} integration test",
        key = "integration-test-${testName}",
        target = Size.Medium,
        depends_on = dependsOn,
        if = Some "build.branch != 'develop' && build.branch != 'compatible' && build.branch != 'develop-next'"
      },

  buildJs = \() -> 
    Command.build
      Command.Config::{
        commands =
            -- Build js test archive
            RunInToolchain.runInToolchainBuster [] "./buildkite/scripts/build-js-tests.sh"
            
            #

            [
              -- Cache js test archive
              Cmd.run "artifact-cache-helper.sh snarkyjs_test.tar.gz --upload"
            ],
        label = "Build JS integration tests",
        key = "build-js-tests",
        target = Size.XLarge,
        if = Some "build.branch != 'develop' && build.branch != 'compatible' && build.branch != 'develop-next'"
      },

  executeWithJs = \(testName : Text) -> \(dependsOn : List Command.TaggedKey.Type) ->
    Command.build
      Command.Config::{
        commands =
            [
              -- Download test dependencies
              Cmd.run "artifact-cache-helper.sh test_executive.exe && chmod +x test_executive.exe",
              Cmd.run "artifact-cache-helper.sh logproc.exe && chmod +x logproc.exe",
              Cmd.run "artifact-cache-helper.sh snarkyjs_test.tar.gz && tar -xzf snarkyjs_test.tar.gz",
              Cmd.run (
                  "[ ! -f ${defaultArtifactStep.deploy_env_file} ] && buildkite-agent artifact download --build \\\$BUILDKITE_BUILD_ID " ++
                      "--include-retried-jobs --step _${defaultArtifactStep.name}-${defaultArtifactStep.key} ${defaultArtifactStep.deploy_env_file} ."
              ),

              -- Execute test based on BUILD image
              Cmd.run "MINA_DEB_CODENAME=buster ; source ${defaultArtifactStep.deploy_env_file} && ./buildkite/scripts/run-test-executive.sh ${testName}"
            ],
        artifact_paths = [SelectFiles.exactly "." "${testName}.test.log"],
        label = "${testName} integration test",
        key = "integration-test-${testName}",
        target = Size.Medium,
        depends_on = dependsOn,
        if = Some "build.branch != 'develop' && build.branch != 'compatible' && build.branch != 'develop-next'"
      }
}
