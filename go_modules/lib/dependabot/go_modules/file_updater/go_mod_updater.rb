# frozen_string_literal: true

require "dependabot/shared_helpers"
require "dependabot/errors"
require "dependabot/go_modules/file_updater"
require "dependabot/go_modules/native_helpers"

module Dependabot
  module GoModules
    class FileUpdater
      class GoModUpdater
        # Turn off the module proxy for now, as it's causing issues with
        # private git dependencies
        ENVIRONMENT = { "GOPRIVATE" => "*" }.freeze

        RESOLVABILITY_ERROR_REGEXES = [
          /go: .*: git fetch .*: exit status 128/.freeze,
          /verifying .*: checksum mismatch/.freeze,
          /build .*: cannot find module providing package/.freeze
        ].freeze

        MODULE_PATH_MISMATCH_REGEXES = [
          /go: ([^@\s]+)(?:@[^\s]+)?: .* has non-.* module path "(.*)" at/,
          /go: ([^@\s]+)(?:@[^\s]+)?: .* unexpected module path "(.*)"/,
          /go: ([^@\s]+)(?:@[^\s]+)?: .* declares its path as: ([\S]*)/m
        ].freeze

        def initialize(dependencies:, credentials:, repo_contents_path:)
          @dependencies = dependencies
          @credentials = credentials
          @repo_contents_path = repo_contents_path
        end

        def updated_go_mod_content
          updated_files[:go_mod]
        end

        def updated_go_sum_content
          updated_files[:go_sum]
        end

        private

        attr_reader :dependencies, :credentials, :repo_contents_path

        def updated_files
          @updated_files ||= update_files
        end

        def update_files
          in_repo_path do
            # Map paths in local replace directives to path hashes

            original_go_mod = File.read("go.mod")
            original_manifest = parse_manifest
            original_go_sum = File.read("go.sum") if File.exist?("go.sum")

            substitutions = replace_directive_substitutions(original_manifest)
            build_module_stubs(substitutions.values)

            # Replace full paths with path hashes in the go.mod
            substitute_all(substitutions)

            # Set the stubbed replace directives
            update_go_mod(dependencies)

            # Then run `go get` to pick up other changes to the file caused by
            # the upgrade
            run_go_get
            run_go_mod_tidy

            # At this point, the go.mod returned from run_go_get contains the
            # correct set of modules, but running `go get` can change the file
            # in undesirable ways (such as injecting the current Go version),
            # so we need to update the original go.mod with the updated set of
            # requirements rather than using the regenerated file directly
            original_reqs = original_manifest["Require"] || []
            updated_reqs = parse_manifest["Require"] || []

            original_paths = original_reqs.map { |r| r["Path"] }
            updated_paths = updated_reqs.map { |r| r["Path"] }
            req_paths_to_remove = original_paths - updated_paths

            # Put back the original content before we replace just the updated
            # dependencies.
            write_go_mod(original_go_mod)

            remove_requirements(req_paths_to_remove)
            deps = updated_reqs.map { |r| requirement_to_dependency_obj(r) }
            update_go_mod(deps)

            # put the old replace directives back again
            substitute_all(substitutions.invert)

            updated_go_sum = original_go_sum ? File.read("go.sum") : nil
            updated_go_mod = File.read("go.mod")

            { go_mod: updated_go_mod, go_sum: updated_go_sum }
          end
        end

        def run_go_mod_tidy
          command = "go mod tidy"
          _, stderr, status = Open3.capture3(ENVIRONMENT, command)
          handle_subprocess_error(stderr) unless status.success?
        end

        def update_go_mod(dependencies)
          deps = dependencies.map do |dep|
            {
              name: dep.name,
              version: "v" + dep.version.sub(/^v/i, ""),
              indirect: dep.requirements.empty?
            }
          end

          body = SharedHelpers.run_helper_subprocess(
            command: NativeHelpers.helper_path,
            env: ENVIRONMENT,
            function: "updateDependencyFile",
            args: { dependencies: deps }
          )

          write_go_mod(body)
        end

        def run_go_get
          unless Dir.glob("*.go").any?
            File.write("main.go", "package dummypkg\n")
          end

          _, stderr, status = Open3.capture3(ENVIRONMENT, "go get -d")
          handle_subprocess_error(stderr) unless status.success?
        end

        def parse_manifest
          command = "go mod edit -json"
          stdout, stderr, status = Open3.capture3(ENVIRONMENT, command)
          handle_subprocess_error(stderr) unless status.success?

          JSON.parse(stdout) || {}
        end

        def remove_requirements(requirement_paths)
          requirement_paths.each do |path|
            escaped_path = Shellwords.escape(path)
            command = "go mod edit -droprequire #{escaped_path}"
            _, stderr, status = Open3.capture3(ENVIRONMENT, command)
            handle_subprocess_error(stderr) unless status.success?
          end
        end

        def add_requirements(requirements)
          requirements.each do |r|
            escaped_req = Shellwords.escape("#{r['Path']}@#{r['Version']}")
            command = "go mod edit -require #{escaped_req}"
            _, stderr, status = Open3.capture3(ENVIRONMENT, command)
            handle_subprocess_error(stderr) unless status.success?
          end
        end

        def in_repo_path(&block)
          SharedHelpers.
            in_a_temporary_repo_directory("/", repo_contents_path) do
            SharedHelpers.with_git_configured(credentials: credentials) do
              block.call
            end
          end
        end

        def build_module_stubs(stub_paths)
          # Create a fake empty module for each local module so that
          # `go get -d` works, even if some modules have been `replace`d
          # with a local module that we don't have access to.
          stub_paths.each do |stub_path|
            Dir.mkdir(stub_path) unless Dir.exist?(stub_path)
            FileUtils.touch(File.join(stub_path, "go.mod"))
            FileUtils.touch(File.join(stub_path, "main.go"))
          end
        end

        # Given a go.mod file, find all `replace` directives pointing to a path
        # on the local filesystem, and return an array of pairs mapping the
        # original path to a hash of the path.
        #
        # This lets us substitute all parts of the go.mod that are dependent on
        # the layout of the filesystem with a structure we can reproduce (i.e.
        # no paths such as ../../../foo), run the Go tooling, then reverse the
        # process afterwards.
        def replace_directive_substitutions(manifest)
          @replace_directive_substitutions ||=
            begin
              # Find all the local replacements, and return them with a stub
              # path we can use in their place. Using generated paths is safer
              # as it means we don't need to worry about references to parent
              # directories, etc.
              (manifest["Replace"] || []).
                map { |r| r["New"]["Path"] }.
                compact.
                select { |p| p.start_with?(".") || p.start_with?("/") }.
                map { |p| [p, "./" + Digest::SHA2.hexdigest(p)] }.
                to_h
            end
        end

        def substitute_all(substitutions)
          body = substitutions.reduce(File.read("go.mod")) do |text, (a, b)|
            text.sub(a, b)
          end

          write_go_mod(body)
        end

        def handle_subprocess_error(stderr)
          stderr = stderr.gsub(Dir.getwd, "")

          error_regex = RESOLVABILITY_ERROR_REGEXES.find { |r| stderr =~ r }
          if error_regex
            lines = stderr.lines.drop_while { |l| error_regex !~ l }
            raise Dependabot::DependencyFileNotResolvable.new, lines.join
          end

          path_regex = MODULE_PATH_MISMATCH_REGEXES.find { |r| stderr =~ r }
          if path_regex
            match = path_regex.match(stderr)
            raise Dependabot::GoModulePathMismatch.
              new(relative_go_mod_path, match[1], match[2])
          end

          msg = stderr.lines.last(10).join.strip
          raise Dependabot::DependencyFileNotParseable.
            new(relative_go_mod_path, msg)
        end

        def relative_go_mod_path
          # This grabs the path to the go.mod file, relatively to the git root
          # path, we use this in error messages to signal which go.mod file in a
          # project ran into issues.
          return @relative_go_mod_path if @relative_go_mod_path

          git_root = SharedHelpers.
                     run_shell_command("git rev-parse --show-toplevel").strip
          root_path = Pathname.new(git_root).cleanpath.to_s
          absolute_path = Pathname.new(Dir.getwd).cleanpath.to_s
          directory = absolute_path.gsub(root_path, "")

          @relative_go_mod_path =
            File.join([directory, "go.mod"].reject(&:empty?))
        end

        def requirement_to_dependency_obj(req)
          # This is an approximation - we're not correctly populating `source`
          # for instance, but it's only to plug the requirement into the
          # `update_go_mod` method so this mapping doesn't need to be perfect
          dep_req = {
            file: "go.mod",
            requirement: req["Version"],
            groups: [],
            source: nil
          }
          Dependency.new(
            name: req["Path"],
            version: req["Version"],
            requirements: req["Indirect"] ? [] : [dep_req],
            package_manager: "go_modules"
          )
        end

        def write_go_mod(body)
          File.write("go.mod", body)
        end
      end
    end
  end
end
