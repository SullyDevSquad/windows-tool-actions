# frozen_string_literal: true

require "psych"

root = File.expand_path("..", __dir__)
files = Dir.glob(File.join(root, "**", "*.{yml,yaml}"), File::FNM_EXTGLOB)
files.concat(Dir.glob(File.join(root, ".github", "**", "*.{yml,yaml}"), File::FNM_EXTGLOB))
files.uniq.sort.each do |path|
  Psych.parse_file(path)
  puts "Parsed #{path.delete_prefix("#{root}/")}"
rescue Psych::SyntaxError => e
  warn e.message
  exit 1
end
