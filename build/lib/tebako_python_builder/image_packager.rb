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

module TebakoPythonBuilder
  # Packs the assembled layout tree into the standalone image published
  # next to the runtime executable:
  # tebako-runtime-<tebako>-<python>-<platform>.tfs.
  #
  # One tool only: the pin-verified tfs CLI (TfsTool), `tfs mkimage`
  # WITHOUT a --format flag — the default format is limnifs (spec 20 §6),
  # the image format the product's readers resolve by auto-detect. There
  # is deliberately no mkdwarfs fallback (the ruby factory's second path):
  # the pinned CLI is always resolvable, and a fallback format would drift
  # the published image kind from the default.
  class ImagePackager
    def initialize(platform, tfs:)
      @platform = platform
      @tfs = tfs
    end

    def package(layout_dir, image_path)
      unless File.directory?(layout_dir)
        raise TebakoPythonBuilder::Error.new(
          "runtime layout tree #{layout_dir} does not exist (the assemble step did not run)", 131
        )
      end

      FileUtils.mkdir_p(File.dirname(image_path))
      FileUtils.rm_f(image_path)
      puts "-- Packing the runtime layout as #{image_path} (tfs mkimage, the default limnifs format)"
      TebakoPythonBuilder::BuildHelpers.run_with_capture_v([@tfs, "mkimage", layout_dir, "-o", image_path])
      image_path
    rescue TebakoPythonBuilder::Error => e
      raise e if e.error_code == 131 && e.message.include?("layout tree")

      raise TebakoPythonBuilder::Error.new("runtime image packaging failed: #{e.message}", 131)
    end
  end
end
