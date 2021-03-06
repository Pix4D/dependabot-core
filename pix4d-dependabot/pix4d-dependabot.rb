# frozen_string_literal: true

require "helpers/helper_dependabot"
require "yaml"

# LIST OF ENVIROMENTAL VARIABLES NEEDED:
# GITHUB_ACCESS_TOKEN
# REPOSITORY_DATA list of dictionaries. Each dictionary should contain the following keys:
#   - module i.e docker, concourse, pip
#   - repo i.e. Pix4D/test-dependabot-python
#   - branch i.e master
#   - dependency_dir i.e. /, ci/docker, ci/pipelines, project/requirements

# REQUIRED DEPENDING ON MODULE:

## DOCKER/CONCOURSE MODULE
## DOCKER_REGISTRY i.e. docker.ci.pix4d.com
## DOCKER_USER
## DOCKER_PASS

def create_extra_credentials(package_manager)
  return unless package_manager == "docker"

  {
    "type" => "docker_registry",
    "registry" => (ENV["DOCKER_REGISTRY"] || "registry.hub.docker.com"),
    "username" => (ENV["DOCKER_USER"] || nil),
    "password" => (ENV["DOCKER_PASS"] || nil)
  }
end

def main
  credentials_github = {
    "type" => "git_source",
    "host" => "github.com",
    "username" => "dependabot-script",
    "password" => (ENV["GITHUB_ACCESS_TOKEN"] || nil)
  }

  ENV["REPOSITORY_DATA"] || raise("Environmental variable REPOSITORY_DATA is not set")

  input_data = YAML.safe_load(ENV["REPOSITORY_DATA"], [], [], true)

  unless input_data.is_a?(Array) && !input_data.empty?
    raise TypeError,
          "REPOSITORY_DATA should be a non-empty list of dictonaries"
  end

  input_data.each do |project_data|
    raise KeyError, "REPOSITORY_DATA items should not be empty" if project_data.keys.empty?

    missing_keys = %w(module repo branch dependency_dir) - project_data.keys
    raise KeyError, "Each REPOSITORY_DATA item should contain 3 non empty keys" unless missing_keys.empty?

    package_manager = if project_data["module"] == "concourse"
                        "docker"
                      else
                        project_data["module"]
                      end
    extra_credentials = create_extra_credentials(package_manager)

    pix4_dependabot(package_manager, project_data, credentials_github, extra_credentials)
  end
end

# PROGRAM ENTRY POINT
main if __FILE__ == $PROGRAM_NAME
