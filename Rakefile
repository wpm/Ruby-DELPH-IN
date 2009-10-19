require 'rubygems'
gem 'hoe', '>= 2.1.0'
require 'hoe'
require 'fileutils'
require './lib/delphin'

Hoe.plugin :newgem
Hoe.plugin :website

# Generate all the Rake tasks
# Run 'rake -T' to see list of generated tasks (from gem root directory)
$hoe = Hoe.spec 'delphin' do
  self.developer 'W.P. McNeill', 'billmcn@gmail.com'
  self.rubyforge_name       = self.name # TODO this is default value
  self.description = <<-EOF
  This module is a Ruby wrapper for the DELPH-IN project.
  EOF
  self.summary = "Ruby utilities for the DELPH-IN project"
end

require 'newgem/tasks'
Dir['tasks/**/*.rake'].each { |t| load t }
