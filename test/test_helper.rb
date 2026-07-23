# frozen_string_literal: true

# Standalone harness: nothing from Rails or the host app is loaded. The
# helper scripts under bin/ are plain Ruby (stdlib only), so the suite
# `load`s the one under test and exercises its pure methods. Each script
# guards its #main with `if $PROGRAM_NAME == __FILE__`, so loading it here
# defines its module without running the delivery path.
$LOAD_PATH.unshift File.expand_path("../bin", __dir__)

require "minitest/autorun"

BIN_DIR = File.expand_path("../bin", __dir__)

# Load a bin/ helper script by name (they have no .rb extension, so
# `require` won't find them; `load` runs the file, and the module-vs-main
# guard keeps it side-effect free).
def load_bin(name)
  load File.join(BIN_DIR, name)
end

# Minimal stand-in for the Rails-style `test "..."` declaration so suites
# read like the sibling repos' without pulling in ActiveSupport.
module Minitest
  class Test
    def self.test(name, &block)
      define_method("test_#{name.gsub(/\W+/, '_')}", &block)
    end
  end
end
