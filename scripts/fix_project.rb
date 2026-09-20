require 'xcodeproj'

project = Xcodeproj::Project.open('Brim.xcodeproj')
target = project.targets.find { |t| t.name == 'brim' }

# 1. Drop the stray plain-file reference to the package directory.
project.main_group.children.dup.each do |child|
  child.remove_from_project if child.isa == 'PBXFileReference' && child.path == 'BrimCore'
end

# 2. Drop any pre-existing (and orphaned) package product wiring.
target.frameworks_build_phase.files.dup.each do |bf|
  bf.remove_from_project if bf.product_ref
end
target.package_product_dependencies.dup.each { |d| d.remove_from_project }
project.root_object.package_references.dup.each { |p| p.remove_from_project }

# 3. Reference the local BrimCore package and link the products the app imports.
local_pkg = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
local_pkg.relative_path = 'BrimCore'
project.root_object.package_references << local_pkg

%w[BrimCore BrimProtocol BrimService BrimUI].each do |product|
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = product
  target.package_product_dependencies << dep

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  target.frameworks_build_phase.files << build_file
end

# 4. Brim scans the whole filesystem and talks to a privileged helper; the
#    App Sandbox makes both impossible.
target.build_configurations.each do |config|
  config.build_settings['ENABLE_APP_SANDBOX'] = 'NO'
  config.build_settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
  config.build_settings.delete('ENABLE_USER_SELECTED_FILES')
end

project.save
puts "linked: #{target.package_product_dependencies.map(&:product_name).join(', ')}"
