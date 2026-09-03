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

require "fileutils"
require "yaml"

module TebakoPythonBuilder
  # Assembles the env image's layout tree from the staged install
  # (PythonBuild#staged_prefix_tree): the stdlib + lib-dynload + the
  # SELECTED site-packages (build/site-packages.yml — the declarative
  # whitelist; v1 ships pip only), the tebako contract card
  # (lib/tebako/layout.yaml), the preload shim (POSIX — REQUIRED: the
  # unpatched interpreter cannot read its own mounted image without it,
  # so a missing shim is a hard error here, never the ruby factory's
  # degrade), and the L1 payload manifest (__tpkg__/manifest.yaml).
  #
  # The interpreter binary itself is NOT in the image — the exe ships
  # beside it (the image-era runtime's two-artifact shape; the bin/ dir
  # also carries the ensurepip console scripts whose build-prefix
  # shebangs would be dead links — README's pip3 decision).
  #
  # The pruned stdlib members (test/, idlelib, tkinter/turtle — the
  # *disabled* extensions' python sides, and the test suite) are the v1
  # hermetic-core call: the runtime answers "no such module" by absence,
  # never by a broken import.
  class ImageBuilder
    # The env image's own contract declaration (spec 18 C3), read by the
    # driver post-mount, before the interpreter starts: a missing layout
    # is an era-1 refusal; a mount_root != the exe's compiled-in root is
    # exit 78. Field set per docs/spec/schemas/layout.yaml (snake_case):
    # schema/version, era, image_layout, mount_root,
    # interpreter_api_version; the additive mount_root_override grant
    # (schema_minor 1) is emitted ALWAYS — truthful by construction: the
    # fs TU sets PYTHONHOME from tebako_mount_point(), the driver's
    # effective root, so the interpreter follows TEBAKO_MOUNT_ROOT (the
    # factory owns both sides of the grant; the boot smoke asserts the
    # chain end-to-end). The additive preload_shim grant (schema_minor 2)
    # names exactly the staged shim's in-image path.
    LAYOUT_DECLARATION = {
      "schema" => "layout",
      "schema_version" => 1,
      "era" => 2,
      "image_layout" => 1
    }.freeze
    LAYOUT_PATH = File.join("lib", "tebako", "layout.yaml").freeze

    # Pruned under the staged prefix tree (relative spellings;
    # <libdir> is pythonX.Y). The interpreter exe ships beside the image,
    # so bin/ never rides; include/ + the static libpython + pkgconfig are
    # the build-time surface a read-only runtime image never needs (the
    # xml2rfc-class payload installs pure-python wheels); share/ is man
    # pages.
    PRUNE_TOP = %w[bin include share].freeze
    PRUNE_FILES = ["lib/pkgconfig"].freeze
    # Pruned under lib/pythonX.Y/: the test suite and the disabled
    # extensions' python sides.
    PRUNE_STDLIB = %w[test idlelib tkinter turtledemo turtle.py].freeze
    # lib-dynload members pruned by glob: the test-extension set (built by
    # default; never importable by a payload).
    PRUNE_DYNLOAD_GLOBS = %w[_test* _ctypes_test* xxsubtype* _xx*].freeze

    def initialize(platform:, python_version:, tebako_version:, src_sha256:, patch_set:, # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength
                   link_unit:, link_unit_dir:, repo_root:)
      @platform = platform
      @python = TebakoPythonBuilder::PythonVersion.new(python_version)
      @tebako_version = tebako_version
      @src_sha256 = src_sha256
      @patch_set = patch_set
      @link_unit = link_unit
      @link_unit_dir = link_unit_dir
      @repo_root = repo_root
    end

    # Copy the staged prefix tree into a fresh tree at dest and deploy the
    # tebako surface; returns dest (the image root — its CONTENTS map onto
    # the mount root).
    def assemble(staged_tree, dest)
      FileUtils.rm_rf(dest, secure: true)
      FileUtils.mkdir_p(dest)
      FileUtils.cp_r("#{staged_tree}/.", dest)
      prune(dest)
      deploy_preload(dest)
      deploy_layout(dest)
      deploy_manifest(dest)
      dest
    end

    private

    def prune(tree)
      PRUNE_TOP.each { |d| FileUtils.rm_rf(File.join(tree, d), secure: true) }
      PRUNE_FILES.each { |f| FileUtils.rm_rf(File.join(tree, f), secure: true) }
      FileUtils.rm_rf(Dir.glob(File.join(tree, "lib", "libpython*.a")), secure: true)

      libdir = File.join(tree, "lib", @python.libdir_name)
      unless File.directory?(libdir)
        raise TebakoPythonBuilder::Error.new(
          "the staged install carries no lib/#{@python.libdir_name} stdlib tree under #{tree}", 105
        )
      end
      PRUNE_STDLIB.each { |d| FileUtils.rm_rf(File.join(libdir, d), secure: true) }
      PRUNE_DYNLOAD_GLOBS.each do |glob|
        FileUtils.rm_rf(Dir.glob(File.join(libdir, "lib-dynload", glob)), secure: true)
      end
      prune_site_packages(libdir)
    end

    # The site-packages whitelist (build/site-packages.yml): everything
    # not named is pruned. `pip` keeps its dist-info (pip's own
    # importlib.metadata self-check reads it).
    def prune_site_packages(libdir)
      site = File.join(libdir, "site-packages")
      return unless File.directory?(site)

      keep = site_packages_keep
      Dir.children(site).each do |entry|
        keep_entry = keep.include?(entry) ||
                     keep.any? { |name| entry.start_with?("#{name}-") && entry.end_with?(".dist-info") }
        next if keep_entry

        puts "   ... pruning site-packages/#{entry} (not in build/site-packages.yml)"
        FileUtils.rm_rf(File.join(site, entry), secure: true)
      end
    end

    def site_packages_keep
      path = File.join(@repo_root, "build", "site-packages.yml")
      data = YAML.load_file(path)
      list = data.is_a?(Hash) ? data["keep"] : nil
      unless list.is_a?(Array) && list.all? { |entry| entry.is_a?(String) && !entry.empty? }
        raise TebakoPythonBuilder::Error.new("#{path}: expected a 'keep' list of names", 105)
      end
      list
    end

    # The preload shim rides the env image at lib/tebako/ and is declared
    # via the layout's preload_shim grant, which the driver flows to the
    # injection env (LD_PRELOAD / DYLD_INSERT_LIBRARIES) and
    # TEBAKO_PRELOAD_SHIM. Unlike the ruby factory (whose interpreter is
    # patched and degrades gracefully), the unpatched CPython CANNOT read
    # its own mounted image without the shim — its absence from the link
    # unit is a hard error (LinkUnit already fails the same way; this is
    # the staging side of the declaration's truthfulness).
    def deploy_preload(tree)
      return if @platform.msys?

      src = @link_unit.preload_shim_path(@link_unit_dir)
      unless src && File.file?(src)
        raise TebakoPythonBuilder::Error.new(
          "no preload shim in the link unit at #{@link_unit_dir} — the image cannot declare " \
          "what it does not hold (the fs TU refuses such a boot with exit 78)", 131
        )
      end

      dest = File.join(tree, "lib", "tebako")
      FileUtils.mkdir_p(dest)
      FileUtils.cp(src, File.join(dest, File.basename(src)))
      puts "   ... preload shim: #{File.join(dest, File.basename(src))}"
    end

    def deploy_layout(tree)
      path = File.join(tree, LAYOUT_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      declaration = LAYOUT_DECLARATION.merge(
        "mount_root" => @platform.mount_root,
        "interpreter_api_version" => @python.api_version,
        "mount_root_override" => true
      )
      unless @platform.msys?
        declaration["preload_shim"] = File.join("lib", "tebako", @link_unit.preload_shim_name)
      end
      File.write(path, YAML.dump(declaration))
      puts "   ... env image layout declaration: #{path}"
    end

    def deploy_manifest(tree)
      path = TebakoPythonBuilder::ImageManifest.new(platform: @platform,
                                                    python_version: @python.python_version,
                                                    tebako_version: @tebako_version,
                                                    patch_set: @patch_set,
                                                    src_sha256: @src_sha256).deploy(tree)
      puts "   ... env image payload manifest: #{path}"
    end
  end
end
