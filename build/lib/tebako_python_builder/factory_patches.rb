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

require "digest"
require "open3"
require "tempfile"

module TebakoPythonBuilder
  # The factory patch set (patches/README.md's contract): the exception of
  # record for a fix the windows-msys runtime build needs while the pinned
  # tamatebako/python source_release does not carry it. The CPython patch
  # SERIES is the source factory's (shipped pre-applied in the
  # windows-msys scenario tarball); a patch lands here only with
  # provenance, a wall, and a removal note — and leaves when the source
  # release grows it. POSIX builds never carry one: their autoconf path is
  # correct by construction (the motivating defect, #105's missing
  # sem_unlink export, is the mingw configure probe's artifact), so #paths
  # is empty off msys and PythonBuild's call is a no-op there.
  #
  # The grammar this class owns (invariant 10): patches/<line>/
  # <feature>_msys.patch, applied in sorted order.
  class FactoryPatches
    # The apply step's named failure: a patch that neither applies cleanly
    # nor is already present means the line's source drifted from the
    # patch's context — re-author or drop the patch, never a silent
    # half-patched tree.
    APPLY_ERROR_CODE = 108

    def initialize(platform:, python_version:, repo_root:)
      @platform = platform
      @python = python_version.is_a?(TebakoPythonBuilder::PythonVersion) ? python_version : TebakoPythonBuilder::PythonVersion.new(python_version)
      @repo_root = repo_root
    end

    # The set for this (platform, line): absolute paths, sorted (apply
    # order). Empty off msys or for a line with no factory patch dir.
    def paths
      return [] unless @platform.msys?

      Dir.glob(File.join(@repo_root, "patches", @python.abi_line, "*_msys.patch")).sort
    end

    # The set's content fingerprint. PythonBuild folds it into the extract
    # marker on msys, so an edited patch set with an unchanged source pin
    # re-extracts the tree (a cached tree is only ever re-probed against
    # the SAME patch bytes). "" for the empty set: the marker then keeps
    # its pre-machinery spelling byte for byte.
    def fingerprint
      return "" if paths.empty?

      Digest::SHA256.hexdigest(
        paths.map { |path| "#{File.basename(path)}:#{TebakoPythonBuilder::BuildHelpers.sha256_file(path)}" }.join("\n")
      )
    end

    # Apply the set to the extracted source tree. Per patch, the state
    # machine (git apply — prompt-free, fuzz-free, and present on every
    # msys leg, the workflow's pacman set):
    #
    #   forward --check ok          -> apply, then assert the tree carries
    #                                  the patch (the reverse check)
    #   forward fails, reverse ok   -> already present: a cached rebuild,
    #                                  or the pinned source release grew
    #                                  the fix — skip loudly (the removal
    #                                  note's window), never re-apply
    #   both fail                   -> the line's source drifted from the
    #                                  patch's context: named error 108
    def apply(src_dir)
      paths.each do |patch_file|
        name = File.basename(patch_file)
        with_apply_input(patch_file) do |input|
          if git_apply_check(src_dir, input)
            git_apply(src_dir, input)
            verify_carried(src_dir, input, name)
            puts "   ... factory patch applied: #{name}"
          elsif git_apply_check(src_dir, input, reverse: true)
            puts "   ... factory patch #{name} already present in the tree " \
                 "(a cached rebuild, or the pinned source carries the fix — " \
                 "drop the file on the source_release bump that picks it up)"
          else
            raise TebakoPythonBuilder::Error.new(
              "factory patch #{name} neither applies to nor is present in #{src_dir} — the " \
              "#{@python.abi_line} line's source drifted from the patch's context; re-author the " \
              "patch against the new tree or drop it (patches/README.md's removal rule)", APPLY_ERROR_CODE
            )
          end
        end
      end
    end

    private

    # The patch input git consumes: the committed file, or an LF-normalized
    # temp copy when the checkout re-encoded it (a windows autocrlf
    # checkout spells the .patch CRLF; every context line then mismatches
    # the LF source tree — the first windows run of the change that
    # introduced this machinery died exactly so). The repo pins eol=lf in
    # .gitattributes; this normalization is the loud backstop, never a
    # silent rewrite — the note lands in the leg's log.
    def with_apply_input(patch_file)
      bytes = File.binread(patch_file)
      unless bytes.include?("\r\n")
        yield patch_file
        return
      end

      puts "   ... #{File.basename(patch_file)} is CRLF-encoded by this checkout " \
           "(.gitattributes pins eol=lf) — applying the LF-normalized bytes"
      Tempfile.create(["factory-patches", ".patch"]) do |tmp|
        tmp.binmode
        tmp.write(bytes.gsub("\r\n", "\n"))
        tmp.flush
        yield tmp.path
      end
    end

    # The build tree sits under the factory's own checkout, so repo
    # discovery must stop at the tree's parent: inside an enclosing repo
    # `git apply` interprets the patch's paths against the REPO root and
    # silently SKIPS them with a green exit — the anti-verification.
    def git_env(src_dir)
      { "GIT_CEILING_DIRECTORIES" => File.dirname(src_dir) }
    end

    def git_apply_check(src_dir, patch_file, reverse: false)
      args = ["git", "apply", "--check"]
      args << "--reverse" if reverse
      args << patch_file
      _out, st = Open3.capture2e(git_env(src_dir), *args, chdir: src_dir, stdin_data: "")
      st.exitstatus&.zero? || false
    end

    def git_apply(src_dir, patch_file)
      args = ["git", "apply", "--verbose", patch_file]
      out, st = Open3.capture2e(git_env(src_dir), *args, chdir: src_dir, stdin_data: "")
      TebakoPythonBuilder::BuildHelpers.log_capture(args, out, st)
      return if st.exitstatus&.zero?

      raise TebakoPythonBuilder::Error.new(
        "git apply failed for factory patch #{File.basename(patch_file)} in #{src_dir} " \
        "(the --check probe just passed — a mid-apply tree change): #{out}", APPLY_ERROR_CODE
      )
    end

    # The post-apply assertion: the tree must now carry the patch (the
    # reverse --check's domain). git apply -N-style leniency never ships a
    # silent skip here.
    def verify_carried(src_dir, patch_file, name)
      return if git_apply_check(src_dir, patch_file, reverse: true)

      raise TebakoPythonBuilder::Error.new(
        "factory patch #{name} applied in #{src_dir} but the tree does not carry it " \
        "(the reverse check failed) — refusing a half-patched build", APPLY_ERROR_CODE
      )
    end
  end
end
