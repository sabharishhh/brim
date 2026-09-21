# Adds the privileged daemon to the application bundle.
#
# SMAppService looks for a LaunchDaemon plist inside the app at
# Contents/Library/LaunchDaemons, whose BundleProgram points at an
# executable inside the same bundle. That makes the app and the daemon one
# signed unit: swap the daemon binary and the app's signature no longer
# validates, so macOS will not run it.
#
# Two things have to happen that Xcode's UI does by hand:
#   1. a command line tool target that builds the daemon
#   2. copy phases putting the binary in Contents/MacOS and the plist in
#      Contents/Library/LaunchDaemons
require 'xcodeproj'

project = Xcodeproj::Project.open('Brim.xcodeproj')
app = project.targets.find { |t| t.name == 'brim' }
abort 'no brim target' unless app

if project.targets.any? { |t| t.name == 'BrimJobHelper' }
  puts 'BrimJobHelper target already present'
  exit 0
end

helper = project.new_target(:command_line_tool, 'BrimJobHelper', :osx, '15.0')

# Same signing as the app, or the two cannot be one unit.
app_debug = app.build_configuration_list['Debug']
team = app_debug.build_settings['DEVELOPMENT_TEAM']
helper.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = 'BrimJobHelper'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.sabharishhh.brim.jobhelper'
  config.build_settings['DEVELOPMENT_TEAM'] = team
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
  config.build_settings['SWIFT_VERSION'] = '6.0'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '15.0'
  config.build_settings['SKIP_INSTALL'] = 'YES'
  # Without these a command line tool has no Info.plist, so it signs as
  # its product name, "BrimJobHelper". The app checks the daemon against
  # com.sabharishhh.brim.jobhelper, and nothing would ever satisfy that.
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['CREATE_INFOPLIST_SECTION_IN_BINARY'] = 'YES'
end

# The daemon's two lines. Everything else lives in BrimPrivileged so the
# package's tests cover the code that runs as root.
group = project.main_group.find_subpath('Helper', true)
group.set_source_tree('SOURCE_ROOT')
group.set_path('Helper')
source = group.new_reference('main.swift')
helper.add_file_references([source])

# BrimPrivileged, so the daemon has its rules.
package = app.package_product_dependencies.find { |d| d.product_name == 'BrimUI' }
if package && package.respond_to?(:package)
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.product_name = 'BrimPrivileged'
  dependency.package = package.package
  helper.package_product_dependencies << dependency
  helper.frameworks_build_phase.add_file_reference(
    project.new(Xcodeproj::Project::Object::PBXBuildFile).tap { |bf| bf.product_ref = dependency }
  ) rescue nil
end

# The app builds the daemon first, then copies it in.
app.add_dependency(helper)

executables = app.new_copy_files_build_phase('Embed the privileged daemon')
executables.symbol_dst_subfolder_spec = :executables
executables.add_file_reference(helper.product_reference, true)

daemons = app.new_copy_files_build_phase('Embed the daemon launchd plist')
daemons.dst_subfolder_spec = '1' # the wrapper
daemons.dst_path = 'Contents/Library/LaunchDaemons'
plist = group.new_reference('com.sabharishhh.brim.jobhelper.plist')
daemons.add_file_reference(plist, true)

project.save
puts "added BrimJobHelper, signed with team #{team}"
