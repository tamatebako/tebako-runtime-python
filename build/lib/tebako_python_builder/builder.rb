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
  # End-to-end runtime package build (tools/build_runtime): fetch + verify
  # the pristine CPython source (SHA256 against the tamatebako/python
  # release SHA256SUMS), stage the pin-verified link unit and tfs CLI
  # (the tamatebako/tebako release), build the interpreter with the
  # spec-17 driver linked in (PythonBuild), assemble + pack the env image
  # (ImageBuilder/ImagePackager), and emit the package sidecars
  # (the image's store-shape .sha256, the exe's .abi facet, the era-2
  # .contract.yaml provenance card the release pipeline folds into the
  # manifest entry).
  class Builder
    # The era-2 contract card constants (spec 18 C2): what this factory
    # builds. Written into every package's .contract.yaml sidecar and
    # folded into the release manifest entry by scripts/upload_release.rb.
    CONTRACT_CARD = { "contract_era" => 2, "image_layout" => 1 }.freeze

    def initialize(repo_root:, python_version:, tebako_version:, prefix:, output:, # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength
                   jobs: nil, src_release: nil, src_mirror: nil,
                   link_unit_release: nil, link_unit_pid: nil)
      @repo_root = repo_root
      @python_version = python_version
      @tebako_version = tebako_version
      @prefix = File.expand_path(prefix)
      @output = output
      @jobs = jobs
      contract = TebakoPythonBuilder::Contract.new
      @src_release = src_release || contract.source_release
      @src_mirror = src_mirror
      @link_unit_release = link_unit_release || contract.link_unit_release
      @link_unit_pid = link_unit_pid
      @platform = TebakoPythonBuilder::Platform.new
    end

    def run # rubocop:disable Metrics/MethodLength
      (tarball, sha256) = fetcher.fetch(@python_version)
      puts "-- Building tebako runtime for python #{@python_version} " \
           "(tebako #{@tebako_version}, #{@platform.host_id}, #{File.basename(tarball)})"
      link_unit_dir = link_unit.stage(File.join(@prefix, "link-unit"))
      tfs = tfs_tool.fetch
      build = TebakoPythonBuilder::PythonBuild.new(platform: @platform, python_version: @python_version,
                                                   prefix: @prefix, tarball: tarball, src_sha256: sha256,
                                                   link_unit: link_unit, link_unit_dir: link_unit_dir,
                                                   repo_root: @repo_root, jobs: @jobs)
                                              .run
      finalize(build.exe_path)
      assemble_and_pack_image(build, sha256, link_unit, link_unit_dir, tfs)
      write_image_sidecar
      write_abi_sidecar(build)
      write_contract_sidecar(tarball, sha256, link_unit)
      @output = output
      puts "-- Runtime package: #{output}"
      puts "-- Runtime env image: #{image_output}"
      output
    end

    def default_output
      File.join(Dir.pwd, "runtime-packages",
                "tebako-runtime-#{@tebako_version}-#{@python_version}-#{@platform.host_id}#{@platform.exe_suffix}")
    end

    # The standalone runtime filesystem image published next to the
    # runtime executable (the image era's only filesystem image).
    def image_output
      "#{output.sub(/\.exe\z/, "")}.tfs"
    end

    private

    def output
      @output ||= default_output
    end

    def fetcher
      @fetcher ||= TebakoPythonBuilder::SourceFetcher.new(release: @src_release, mirror: @src_mirror,
                                                          cache_dir: File.join(@prefix, "downloads"))
    end

    def link_unit
      @link_unit ||= TebakoPythonBuilder::LinkUnit.new(release: @link_unit_release, platform: @platform,
                                                       pid: @link_unit_pid,
                                                       cache_dir: File.join(@prefix, "downloads"))
    end

    def tfs_tool
      @tfs_tool ||= TebakoPythonBuilder::TfsTool.new(release: @link_unit_release, platform: @platform,
                                                     cache_dir: File.join(@prefix, "downloads"))
    end

    # The shipped exe is the build tree's driver-linked interpreter,
    # copied (never stripped — the symbol table is the symbol-provenance
    # assert's evidence on EVERY platform, ci/check_symbol_provenance.sh;
    # runtime size is not the gated artifact, the bootstrap is).
    def finalize(built_exe)
      FileUtils.mkdir_p(File.dirname(output))
      FileUtils.cp(built_exe, output)
      FileUtils.chmod(0o755, output)
    end

    def assemble_and_pack_image(build, sha256, link_unit, link_unit_dir, tfs)
      tree = TebakoPythonBuilder::ImageBuilder.new(platform: @platform, python_version: @python_version,
                                                   tebako_version: @tebako_version, src_sha256: sha256,
                                                   patch_set: @src_release,
                                                   link_unit: link_unit, link_unit_dir: link_unit_dir,
                                                   repo_root: @repo_root)
                                              .assemble(build.staged_prefix_tree, File.join(@prefix, "image-tree"))
      TebakoPythonBuilder::ImagePackager.new(@platform, tfs: tfs).package(tree, image_output)
    end

    # The store-layout trust marker next to the image (the store: every
    # cached runtime image carries its <image>.sha256): the leading token
    # is the content key the driver's exec-cache segregation (spec 22 §6)
    # reads. Written at build so a factory tree boots store-faithfully
    # (the boot smoke's TEBAKO_RUNTIME_IMAGE then resolves the same image
    # key the store would give it); never uploaded — upload_release
    # rejects the suffix alongside .abi/.contract.yaml.
    def write_image_sidecar
      hex = TebakoPythonBuilder::BuildHelpers.sha256_file(image_output)
      File.write("#{image_output}.sha256", "#{hex}  #{File.basename(image_output)}\n")
    end

    # The runtime's abi facet (spec 05 §5's abi line — the build's own
    # EXT_SUFFIX stem, exactly what native-extension wheels pin) as
    # `<output>.abi`. The release flow folds it into the manifest entry's
    # additive `abi` key.
    def write_abi_sidecar(build)
      File.write("#{output.sub(/\.exe\z/, "")}.abi", "#{build.abi}\n")
    end

    # The era-2 contract provenance (spec 18 C2) as
    # `<output>.contract.yaml`, folded into the release manifest entry by
    # scripts/upload_release.rb (fail-closed there: a package without it
    # is pre-era and refused). built_from names the source release and the
    # consumed tarball with its verified sha256; the additive link_unit
    # block names the consumed product release's unit and its API-declared
    # digest (open parse — consumers that predate the key ignore it).
    def write_contract_sidecar(tarball, sha256, link_unit)
      card = CONTRACT_CARD.merge(
        "mount_root" => @platform.mount_root,
        "built_from" => {
          "release" => @src_release,
          "sources" => [{ "name" => File.basename(tarball), "sha256" => sha256 }]
        },
        "link_unit" => {
          "release" => @link_unit_release,
          "asset" => link_unit.asset_name
        }
      )
      File.write("#{output.sub(/\.exe\z/, "")}.contract.yaml", YAML.dump(card))
    end
  end
end
