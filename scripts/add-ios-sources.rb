# Adds every Swift file of the iOS folders that its targets do not compile
# yet, in groups that mirror the folders. The xcodeproj gem cannot write
# file-system-synchronized groups, so new iOS sources go in this way.
#
#   ruby scripts/add-ios-sources.rb   (from the repo root)
require 'xcodeproj'

# Folder => the targets compiling it.
FOLDERS = {
  'Ownwave' => ['Ownwave'],
  'Surfaces' => ['Ownwave', 'OwnwaveWidgets'],
  'OwnwaveWidgets' => ['OwnwaveWidgets'],
}.freeze

project = Xcodeproj::Project.open('Ownwave.xcodeproj')
FOLDERS.each do |folder, names|
  targets = names.map { |name| project.targets.find { |t| t.name == name } }
  root = project.main_group[folder] || project.main_group.new_group(folder, folder)
  Dir.glob("#{folder}/**/*.swift").sort.each do |path|
    missing = targets.reject do |target|
      target.source_build_phase.files.any? { |f| f.file_ref&.real_path.to_s == File.expand_path(path) }
    end
    next if missing.empty?
    group = path.split('/')[1..-2].reduce(root) { |g, name| g[name] || g.new_group(name, name) }
    ref = group.files.find { |f| f.path == File.basename(path) } ||
      group.new_reference(File.basename(path))
    missing.each { |target| target.add_file_references([ref]) }
    puts "added #{path} to #{missing.map(&:name).join(', ')}"
  end
end
project.save
