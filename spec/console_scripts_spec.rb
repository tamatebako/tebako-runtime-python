# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe TebakoPythonBuilder::ConsoleScripts do
  # The staged install's site-packages as the real CPython install leaves
  # it: pip's package tree + its dist-info, whose entry_points.txt is the
  # console scripts' metadata owner (pip's own wheel declares both names).
  def stage_tree(dir, entry_points: "[console_scripts]\npip=pip._internal.cli.main:main\npip3=pip._internal.cli.main:main\n")
    libdir = File.join(dir, "lib", "python3.14", "site-packages")
    FileUtils.mkdir_p(File.join(libdir, "pip"))
    FileUtils.mkdir_p(File.join(libdir, "pip-99.0.dist-info"))
    File.write(File.join(libdir, "pip-99.0.dist-info", "entry_points.txt"), entry_points) if entry_points
    dir
  end

  def scripts_for(dir, mount_root: "/__tfs__")
    described_class.new(tree: dir, python_version: "3.14.7", mount_root: mount_root)
  end

  it "stages pip and pip3 from the installed pip's own entry-point metadata" do
    Dir.mktmpdir("tebako-python-console-scripts") do |dir|
      tree = stage_tree(dir)
      expect(scripts_for(tree).deploy).to eq(%w[pip pip3])

      %w[pip pip3].each do |name|
        path = File.join(tree, "bin", name)
        expect(File.file?(path)).to be true
        expect(File.executable?(path)).to be true
        text = File.read(path)
        # The shebang names the image's mount-root interpreter spelling —
        # never a host path, never `#!/usr/bin/env`.
        expect(text.lines.first).to eq("#!/__tfs__/bin/python3\n")
        expect(text).to include("from pip._internal.cli.main import main")
        expect(text).to include("sys.exit(main())")
      end
    end
  end

  it "carries the windows mount root in the shebang on an msys build" do
    Dir.mktmpdir("tebako-python-console-scripts") do |dir|
      tree = stage_tree(dir)
      scripts_for(tree, mount_root: "A:/t").deploy
      expect(File.read(File.join(tree, "bin", "pip")).lines.first).to eq("#!A:/t/bin/python3\n")
    end
  end

  it "refuses by name when the installed pip declares no such console script" do
    Dir.mktmpdir("tebako-python-console-scripts") do |dir|
      tree = stage_tree(dir, entry_points: "[console_scripts]\npip=pip._internal.cli.main:main\n")
      expect { scripts_for(tree).deploy }
        .to raise_error(TebakoPythonBuilder::Error, /declares no \[console_scripts\] entry named 'pip3'/) { |e|
          expect(e.error_code).to eq(105)
        }
    end
  end

  it "refuses by name when the staged site-packages carries no pip dist-info" do
    Dir.mktmpdir("tebako-python-console-scripts") do |dir|
      tree = stage_tree(dir, entry_points: nil)
      expect { scripts_for(tree).deploy }
        .to raise_error(TebakoPythonBuilder::Error, /expected exactly one pip entry_points.txt/) { |e|
          expect(e.error_code).to eq(105)
        }
    end
  end
end
