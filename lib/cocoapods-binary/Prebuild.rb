require_relative 'rome/build_framework'
require_relative 'helper/passer'
require_relative 'helper/target_checker'

# patch prebuild ability
module Pod
  class Installer

    private

    def local_manifest
      self.sandbox.manifest
    end

    # @return [Analyzer::SpecsState]
    def prebuild_pods_changes
      return nil if local_manifest.nil?
      if @prebuild_pods_changes.nil? && !self.analysis_result.nil?
        @prebuild_pods_changes = self.analysis_result.sandbox_state
        # save the changes info for later stage
        Pod::Prebuild::Passer.prebuild_pods_changes = @prebuild_pods_changes
      end
      @prebuild_pods_changes
    end

    public

    # check if need to prebuild
    def have_exact_prebuild_cache?
      # check if need build frameworks
      return false if local_manifest == nil

      changes = prebuild_pods_changes
      return false if changes.nil?

      added = changes.added
      changed = changes.changed
      unchanged = changes.unchanged
      deleted = changes.deleted

      existing_framework_pod_names = sandbox.existing_framework_pod_names
      missing = unchanged.select do |pod_name|
        not existing_framework_pod_names.include?(pod_name)
      end

      needed = (added + changed + deleted + missing)
      return needed.empty?
    end

    # The install method when have completed cache
    def install_when_cache_hit!
      # just print log
      self.sandbox.existed_framework_target_names.each do |name|
        UI.puts "Using #{name}"
      end
    end

    # Build the needed framework files
    def prebuild_frameworks!

      # build options
      sandbox_path = sandbox.root
      existed_framework_folder = sandbox.generate_framework_path
      bitcode_enabled = Pod::Podfile::DSL.bitcode_enabled
      targets = []

      if local_manifest != nil
        changes = prebuild_pods_changes
        added = changes.added
        changed = changes.changed
        unchanged = changes.unchanged
        deleted = changes.deleted

        existed_framework_folder.mkdir unless existed_framework_folder.exist?
        existing_framework_pod_names = sandbox.existing_framework_pod_names

        # additions
        missing = unchanged.select do |pod_name|
          not existing_framework_pod_names.include?(pod_name)
        end

        root_names_to_update = (added + changed + missing)

        # transform names to targets
        cache = []
        targets = root_names_to_update.map do |pod_name|
          tars = Pod.fast_get_targets_for_pod_name(pod_name, self.pod_targets, cache)
          if tars.nil? || tars.empty?
            raise "There's no target named (#{pod_name}) in Pods.xcodeproj.\n #{self.pod_targets.map(&:name)}" if tars.nil?
          end
          tars
        end.flatten

        # add the dependencies
        dependency_targets = targets.map { |t| t.recursive_dependent_targets }.flatten.uniq || []

        # filter already built dependencies
        dependency_targets = dependency_targets.reject { |t|
            local_manifest.version(t.name).to_s.eql? t.version.to_s
        }
        targets = (targets + dependency_targets).uniq
      else
        targets = self.pod_targets
      end

      targets = targets.reject { |pod_target| sandbox.local?(pod_target.pod_name) }

      # build!
      Pod::UI.puts "Prebuild frameworks (total #{targets.count})"
      Pod::Prebuild.remove_build_dir(sandbox_path)
      targets.each do |target|
        if !target.should_build?
          UI.puts "Skipping #{target.label}"
          next
        end

        output_path = sandbox.framework_folder_path_for_target_name(target.name)
        output_path.mkpath unless output_path.exist?

        min_deployment_target = aggregate_targets
                                  .select { |t| t.pod_targets.include?(target) }
                                  .map(&:platform)
                                  .map(&:deployment_target)
                                  .max

        Pod::Prebuild.build(sandbox_path, target, min_deployment_target, output_path, bitcode_enabled, Podfile::DSL.custom_build_options, Podfile::DSL.custom_build_options_simulator)

        # save the resource paths for later installing
        if target.static_framework? and !target.resource_paths.empty?
          framework_path = output_path + target.framework_name
          standard_sandbox_path = sandbox.standard_sandbox_path

          resources = begin
                        if Pod::VERSION.start_with? "1.5"
                          target.resource_paths
                        else
                          # resource_paths is Hash{String=>Array<String>} on 1.6 and above
                          # (use AFNetworking to generate a demo data)
                          # https://github.com/leavez/cocoapods-binary/issues/50
                          target.resource_paths.values.flatten
                        end
                      end
          raise "Wrong type: #{resources}" unless resources.kind_of? Array

          path_objects = resources.map do |path|
            object = Prebuild::Passer::ResourcePath.new
            object.real_file_path = framework_path + File.basename(path)
            object.target_file_path = path.gsub('${PODS_ROOT}', standard_sandbox_path.to_s) if path.start_with? '${PODS_ROOT}'
            object.target_file_path = path.gsub("${PODS_CONFIGURATION_BUILD_DIR}", standard_sandbox_path.to_s) if path.start_with? "${PODS_CONFIGURATION_BUILD_DIR}"
            object
          end
          Prebuild::Passer.resources_to_copy_for_static_framework[target.name] = path_objects
        end

      end
      Pod::Prebuild.remove_build_dir(sandbox_path)

      # copy vendored libraries and frameworks as well as any license
      targets.each do |target|
        root_path = self.sandbox.pod_dir(target.name)
        target_folder = sandbox.framework_folder_path_for_target_name(target.name)

        # If target shouldn't build, we copy all the original files
        # This is for target with only .a and .h files
        if not target.should_build?
          Prebuild::Passer.target_names_to_skip_integration_framework << target.name
          FileUtils.cp_r(root_path, target_folder, :remove_destination => true)
          next
        end

        target.spec_consumers.each do |consumer|
          file_accessor = Sandbox::FileAccessor.new(root_path, consumer)
          preserve_paths = file_accessor.vendored_frameworks || []
          preserve_paths += file_accessor.vendored_libraries
          preserve_paths << file_accessor.license if file_accessor.license
          # @TODO dSYM files
          preserve_paths.each do |path|
            relative = path.relative_path_from(root_path)
            destination = target_folder + relative
            destination.dirname.mkpath unless destination.dirname.exist?
            FileUtils.cp_r(path, destination, :remove_destination => true)
          end
        end
      end

      # save the pod_name for prebuild framwork in sandbox
      targets.each do |target|
        sandbox.save_pod_name_for_target target
      end

      # Remove useless files
      # remove useless pods
      all_needed_names = self.pod_targets.map(&:name).uniq
      useless_target_names = sandbox.existed_framework_target_names.reject do |name|
        all_needed_names.include? name
      end
      useless_target_names.each do |name|
        path = sandbox.framework_folder_path_for_target_name(name)
        path.rmtree if path.exist?
      end

      if not Podfile::DSL.dont_remove_source_code
        # only keep manifest.lock and framework folder in _Prebuild
        to_remain_files = ["Manifest.lock", File.basename(existed_framework_folder)]
        to_delete_files = sandbox_path.children.select do |file|
          filename = File.basename(file)
          not to_remain_files.include?(filename)
        end
        to_delete_files.each do |path|
          path.rmtree if path.exist?
        end
        # keep a tag of the frameworks that have been prebuilt
        all_needed_names.each do |pod_name|
          path = Pathname.new("#{sandbox_path}/#{pod_name}")
          path.rmtree if path.exist?
          path.mkdir
          `touch #{path}/prebuilt`
        end
      else
        # just remove the tmp files
        path = sandbox.root + 'Manifest.lock.tmp'
        path.rmtree if path.exist?
      end
    end

    # patch the post install hook
    old_method2 = instance_method(:run_plugins_post_install_hooks)
    define_method(:run_plugins_post_install_hooks) do
      old_method2.bind(self).()
      if Pod::is_prebuild_stage
        self.prebuild_frameworks!
      else
        path = Pathname.new("#{self.sandbox.root}/_Prebuild/GeneratedFrameworks")
        path.rmtree if path.exist?
      end
    end
  end
end
