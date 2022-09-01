require_relative 'helper/podfile_options'
require_relative 'helper/feature_switches'
require_relative 'helper/prebuild_sandbox'
require_relative 'helper/passer'
require_relative 'helper/names'
require_relative 'helper/target_checker'

# NOTE:
# This file will only be loaded on normal pod install step
# so there's no need to check is_prebuild_stage

# Provide a special "download" process for prebuilded pods.
#
# As the frameworks already exist in local folder. We
# just create a symlink to the original target folder.
#
module Pod
  class Installer
    class PodSourceInstaller

      def install_for_prebuild!(standard_sanbox)
        return if standard_sanbox.local? self.name

        # make a symlink to target folder
        prebuild_sandbox = Pod::PrebuildSandbox.from_standard_sandbox(standard_sanbox)
        # if spec used in multiple platforms, it may return multiple paths
        target_names = prebuild_sandbox.existed_target_names_for_pod_name(self.name)

        def walk(path, &action)
          return unless path.exist?
          path.children.each do |child|
            result = action.call(child, &action)
            if child.directory?
              walk(child, &action) if result
            end
          end
        end

        def make_link(source, target)
          source = Pathname.new(source)
          target = Pathname.new(target)
          target.parent.mkpath unless target.parent.exist?
          # relative_source = source.relative_path_from(target.parent)
          # FileUtils.ln_sf(relative_source, target)
          FileUtils.cp_r(source, target)
        end

        def mirror_with_symlink(source, basefolder, target_folder)
          target = target_folder + source.relative_path_from(basefolder)
          make_link(source, target)
        end

        target_names.each do |name|

          # symbol link copy all substructure
          real_file_folder = prebuild_sandbox.framework_folder_path_for_target_name(name)

          # If have only one platform, just place int the root folder of this pod.
          # If have multiple paths, we use a sperated folder to store different
          # platform frameworks. e.g. AFNetworking/AFNetworking-iOS/AFNetworking.framework
          target_folder = standard_sanbox.pod_dir(self.name)
          if target_names.count > 1
            target_folder += real_file_folder.basename
          end
          target_folder.rmtree if target_folder.exist?
          target_folder.mkpath

          walk(real_file_folder) do |child|
            source = child
            # only make symlink to file and `.framework` folder
            if child.directory? and [".xcframework", ".framework", ".dSYM"].include? child.extname
              mirror_with_symlink(source, real_file_folder, target_folder)
              next false # return false means don't go deeper
            elsif child.file?
              mirror_with_symlink(source, real_file_folder, target_folder)
              next true
            else
              next true
            end
          end

          # symbol link copy resource for static framework
          hash = Prebuild::Passer.resources_to_copy_for_static_framework || {}

          path_objects = hash[name]
          if path_objects != nil
            path_objects.each do |object|
              make_link(object.real_file_path, object.target_file_path)
            end
          end
        end # of for each

      end # of method
    end
  end
end

# Let cocoapods use the prebuild framework files in install process.
#
# the code only effect the second pod install process.
#
module Pod
  class Installer

    # Remove the old target files if prebuild frameworks changed
    def remove_target_files_if_needed
      changes = Pod::Prebuild::Passer.prebuild_pods_changes
      updated_names = []
      if changes == nil
        updated_names = PrebuildSandbox.from_standard_sandbox(self.sandbox).existing_framework_pod_names
      else
        added = changes.added
        changed = changes.changed
        deleted = changes.deleted
        updated_names = added + changed + deleted
      end

      updated_names.each do |name|
        root_name = Specification.root_name(name)
        next if self.sandbox.local?(root_name)

        # delete the cached files
        target_path = self.sandbox.pod_dir(root_name)
        target_path.rmtree if target_path.exist?

        support_path = sandbox.target_support_files_dir(root_name)
        support_path.rmtree if support_path.exist?
      end

    end

    # Modify specification to use only the prebuild framework after analyzing
    old_method2 = instance_method(:resolve_dependencies)
    define_method(:resolve_dependencies) do

      # Remove the old target files, else it will not notice file changes
      self.remove_target_files_if_needed

      # call original
      old_method2.bind(self).()
      # ...
      # ...
      # ...
      # after finishing the very complex original function

      # check the pods
      # Although we have did it in prebuild stage, it's not sufficient.
      # Same pod may appear in another target in form of source code.
      # Prebuild.check_one_pod_should_have_only_one_target(self.prebuild_pod_targets)
      self.validate_every_pod_only_have_one_form

      # prepare
      cache = []

      def add_vendored_framework(spec, platform, added_framework_file_path)
        if spec.attributes_hash[platform] == nil
          spec.attributes_hash[platform] = {}
        end
        vendored_frameworks = spec.attributes_hash[platform]["vendored_frameworks"] || []
        vendored_frameworks = [vendored_frameworks] if vendored_frameworks.kind_of?(String)
        vendored_frameworks += [added_framework_file_path]
        spec.attributes_hash[platform]["vendored_frameworks"] = vendored_frameworks
      end

      def empty_source_files(spec)
        spec.attributes_hash["source_files"] = []
        ["ios", "watchos", "tvos", "osx"].each do |plat|
          if spec.attributes_hash[plat] != nil
            spec.attributes_hash[plat]["source_files"] = []
          end
        end
      end

      specs = self.analysis_result.specifications
      prebuilt_specs = (specs.select do |spec|
        self.prebuild_pod_names.include? spec.root.name
      end)

      prebuilt_specs.each do |spec|
        # Use the prebuild frameworks as vendored frameworks
        # get_corresponding_targets
        targets = Pod.fast_get_targets_for_pod_name(spec.root.name, self.pod_targets, cache)
        targets.each do |target|
          # the framework_file_path rule is decided when `install_for_prebuild`,
          # as to compatible with older version and be less wordy.
          framework_file_path = target.framework_name
          framework_file_path = target.name + "/" + framework_file_path if targets.count > 1
          add_vendored_framework(spec, target.platform.name.to_s, framework_file_path)
        end
        # Clean the source files
        # we just add the prebuilt framework to specific platform and set no source files
        # for all platform, so it doesn't support the sence that 'a pod perbuild for one
        # platform and not for another platform.'
        empty_source_files(spec)

        # to remove the resource bundle target.
        # When specify the "resource_bundles" in podspec, xcode will generate a bundle
        # target after pod install. But the bundle have already built when the prebuit
        # phase and saved in the framework folder. We will treat it as a normal resource
        # file.
        # https://github.com/leavez/cocoapods-binary/issues/29
        if spec.attributes_hash["resource_bundles"]
          bundle_names = spec.attributes_hash["resource_bundles"].keys
          spec.attributes_hash["resource_bundles"] = nil
          spec.attributes_hash["resources"] ||= []
          if spec.attributes_hash.key?("resources") and !spec.attributes_hash["resources"].instance_of?(Array)
            spec.attributes_hash["resources"] = [spec.attributes_hash["resources"]]
          end
          spec.attributes_hash["resources"] += bundle_names.map { |n| n + ".bundle" }
        end

      end

    end

    # Override the download step to skip download and prepare file in target folder
    old_method = instance_method(:install_source_of_pod)
    define_method(:install_source_of_pod) do |pod_name|

      # copy from original
      pod_installer = create_pod_installer(pod_name)
      # \copy from original

      if self.prebuild_pod_names.include? pod_name
        pod_installer.install_for_prebuild!(self.sandbox)
      else
        pod_installer.install!
      end

      # copy from original
      @installed_specs.concat(pod_installer.specs_by_platform.values.flatten.uniq)
      # \copy from original
    end
  end
end

module Pod
  module Generator
    class CopydSYMsScript
      old_method = instance_method(:generate)
      define_method(:generate) do
        script = old_method.bind(self).()
        script = script.gsub(/-av/, "-r -L -p -t -g -o -D -v")
      end
    end
  end
end

module Pod
  module Generator
    class CopyXCFrameworksScript
      old_method = instance_method(:script)
      define_method(:script) do
        script = old_method.bind(self).()
        script = script.gsub(/-av/, "-r -L -p -t -g -o -D -v")
      end
    end
  end
end

Pod::Installer::Xcode::PodsProjectGenerator::PodTargetInstaller.define_singleton_method(:dsym_paths) do |target|
  dsym_paths = target.framework_paths.values.flatten.reject { |fmwk_path| fmwk_path.dsym_path.nil? }.map(&:dsym_path)
  dsym_paths.concat(target.xcframeworks.values.flatten.flat_map { |xcframework| xcframework_dsyms(xcframework.path) })
  dsym_paths.uniq
end

module Pod
  class Installer
    class Xcode
      class PodsProjectGenerator
        class PodTargetIntegrator
          old_method = instance_method(:add_copy_xcframeworks_script_phase)
          define_method(:add_copy_xcframeworks_script_phase) do |native_target|
            script_path = "${PODS_ROOT}/#{target.copy_xcframeworks_script_path.relative_path_from(target.sandbox.root)}"

            input_paths_by_config = {}
            output_paths_by_config = {}

            xcframeworks = target.xcframeworks.values.flatten

            if use_input_output_paths? && !xcframeworks.empty?
              input_file_list_path = target.copy_xcframeworks_script_input_files_path
              input_file_list_relative_path = "${PODS_ROOT}/#{input_file_list_path.relative_path_from(target.sandbox.root)}"
              input_paths_key = UserProjectIntegrator::TargetIntegrator::XCFileListConfigKey.new(input_file_list_path, input_file_list_relative_path)
              input_paths = input_paths_by_config[input_paths_key] = []

              framework_paths = xcframeworks.map { |xcf| "${PODS_ROOT}/#{xcf.path.relative_path_from(target.sandbox.root)}" }
              input_paths.concat framework_paths

              output_file_list_path = target.copy_xcframeworks_script_output_files_path
              output_file_list_relative_path = "${PODS_ROOT}/#{output_file_list_path.relative_path_from(target.sandbox.root)}"
              output_paths_key = UserProjectIntegrator::TargetIntegrator::XCFileListConfigKey.new(output_file_list_path, output_file_list_relative_path)
              output_paths_by_config[output_paths_key] = xcframeworks.map do |xcf|
                "#{Target::BuildSettings::XCFRAMEWORKS_BUILD_DIR_VARIABLE}/#{xcf.name}"
              end
            end

            if xcframeworks.empty?
              UserProjectIntegrator::TargetIntegrator.remove_copy_xcframeworks_script_phase_from_target(native_target)
            else
              UserProjectIntegrator::TargetIntegrator.create_or_update_copy_xcframeworks_script_phase_to_target(
                native_target, script_path, input_paths_by_config, output_paths_by_config)
            end
          end
        end
      end
    end
  end
end
