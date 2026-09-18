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
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.

require "spec_helper"
require "fileutils"
require "tmpdir"
require "yaml"

RSpec.describe TebakoPythonBuilder::ImageBuilder do
  let(:msys_platform) { TebakoPythonBuilder::Platform.new("x86_64-w64-mingw32", "x86_64") }
  let(:posix_platform) { TebakoPythonBuilder::Platform.new("x86_64-pc-linux-gnu", "x86_64") }

  # A staged install prefix in the POSIX spelling `make install` produces
  # on every platform: the stdlib + lib-dynload under lib/pythonX.Y, a
  # kept site-packages member (build/site-packages.yml's whitelist) and a
  # pruned one, the prunable top-level surface, and a prunable
  # test-extension glob member.
  def stage_prefix(dir)
    libdir = File.join(dir, "lib", "python3.14")
    FileUtils.mkdir_p(File.join(libdir, "encodings"))
    FileUtils.mkdir_p(File.join(libdir, "lib-dynload"))
    FileUtils.mkdir_p(File.join(libdir, "site-packages", "pip"))
    FileUtils.mkdir_p(File.join(libdir, "site-packages", "yaml"))
    FileUtils.mkdir_p(File.join(libdir, "test"))
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "lib", "pkgconfig"))
    File.write(File.join(libdir, "os.py"), "# os\n")
    File.write(File.join(libdir, "encodings", "__init__.py"), "# encodings\n")
    File.write(File.join(libdir, "lib-dynload", "_socket.pyd"), "pyd\n")
    File.write(File.join(libdir, "lib-dynload", "_testcapi.pyd"), "pyd\n")
    File.write(File.join(libdir, "site-packages", "pip", "__init__.py"), "# pip\n")
    File.write(File.join(libdir, "site-packages", "yaml", "__init__.py"), "# yaml\n")
    File.write(File.join(libdir, "test", "__init__.py"), "# test\n")
    File.write(File.join(dir, "bin", "python.exe"), "exe\n")
    File.write(File.join(dir, "lib", "pkgconfig", "python-3.14.pc"), "pc\n")
    dir
  end

  def builder_for(platform, link_unit: nil, link_unit_dir: nil)
    described_class.new(platform: platform, python_version: "3.14.7", tebako_version: "9.9.9",
                        src_sha256: "ab" * 32, patch_set: "v0.0.0",
                        link_unit: link_unit, link_unit_dir: link_unit_dir, repo_root: REPO_ROOT)
  end

  it "flattens an msys image into the NT getpath layout (lib/ is Lib and platstdlib in one)" do
    Dir.mktmpdir("tebako-python-image-builder") do |dir|
      dest = File.join(dir, "image")
      builder_for(msys_platform).assemble(stage_prefix(File.join(dir, "staged")), dest)

      # The stdlib and the extension modules answer <prefix>/Lib and
      # <prefix>/lib — one directory on the windows filesystem.
      expect(File.file?(File.join(dest, "lib", "os.py"))).to be true
      expect(File.file?(File.join(dest, "lib", "encodings", "__init__.py"))).to be true
      expect(File.file?(File.join(dest, "lib", "_socket.pyd"))).to be true
      expect(File.exist?(File.join(dest, "lib", "python3.14"))).to be false
      # The prune ran before the flatten: the disabled/test surface and
      # the non-kept site-packages member are gone; pip stays.
      expect(File.exist?(File.join(dest, "lib", "_testcapi.pyd"))).to be false
      expect(File.exist?(File.join(dest, "lib", "test"))).to be false
      expect(File.file?(File.join(dest, "lib", "site-packages", "pip", "__init__.py"))).to be true
      expect(File.exist?(File.join(dest, "lib", "site-packages", "yaml"))).to be false
      expect(File.exist?(File.join(dest, "bin"))).to be false
      # The tebako surface: the layout card keeps its contractual path
      # and declares the runtime DLL; the manifest grants the tier.
      layout = YAML.load_file(File.join(dest, "lib", "tebako", "layout.yaml"))
      expect(layout["mount_root"]).to eq("A:/t")
      expect(layout["runtime_dll"]).to eq("libpython3.14.dll")
      manifest = YAML.load_file(File.join(dest, "__tpkg__", "manifest.yaml"))
      expect(manifest["provides"]["windows_boot"]).to eq("materialize")
    end
  end

  it "keeps the versioned lib/pythonX.Y tree in a POSIX image" do
    Dir.mktmpdir("tebako-python-image-builder") do |dir|
      link_unit_dir = File.join(dir, "link-unit")
      FileUtils.mkdir_p(link_unit_dir)
      File.write(File.join(link_unit_dir, "libtfs_preload.so"), "shim\n")
      link_unit = TebakoPythonBuilder::LinkUnit.new(cache_dir: dir, release: "v9.9.9",
                                                    platform: posix_platform)
      dest = File.join(dir, "image")
      builder_for(posix_platform, link_unit: link_unit, link_unit_dir: link_unit_dir)
        .assemble(stage_prefix(File.join(dir, "staged")), dest)

      libdir = File.join(dest, "lib", "python3.14")
      expect(File.file?(File.join(libdir, "os.py"))).to be true
      expect(File.file?(File.join(libdir, "encodings", "__init__.py"))).to be true
      expect(File.file?(File.join(libdir, "lib-dynload", "_socket.pyd"))).to be true
      expect(File.file?(File.join(dest, "lib", "tebako", "libtfs_preload.so"))).to be true
      layout = YAML.load_file(File.join(dest, "lib", "tebako", "layout.yaml"))
      expect(layout["mount_root"]).to eq("/__tfs__")
      expect(layout["preload_shim"]).to eq("lib/tebako/libtfs_preload.so")
    end
  end
end
