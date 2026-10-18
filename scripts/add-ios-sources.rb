# Adds every Swift file under Ownwave/ that the iOS app target does not
# compile yet, in groups that mirror its folders. The xcodeproj gem cannot
# write file-system-synchronized groups, so new iOS sources go in this way.
#
#   ruby scripts/add-ios-sources.rb   (from the repo root)
require 'xcodeproj'

project = Xcodeproj::Project.open('Ownwave.xcodeproj')
target = project.targets.find { |t| t.name == 'Ownwave' }
root = project.main_group['Ownwave']
existing = target.source_build_phase.files.map { |f| f.file_ref.real_path.to_s }
Dir.glob('Ownwave/**/*.swift').sort.each do |path|
  next if existing.include?(File.expand_path(path))
  group = path.split('/')[1..-2].reduce(root) { |g, name| g[name] || g.new_group(name, name) }
  target.add_file_references([group.new_reference(File.basename(path))])
  puts "added #{path}"
end
project.save
