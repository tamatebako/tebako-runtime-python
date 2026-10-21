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
  # The env image's /bin console scripts — the spawn surface's executables
  # (spec 30 §2 / spec 07 §10). The driver composes a declared entrypoint
  # as `<interpreter argv…> <args_default…> <resolved in-image path> <user
  # args…>` (spec 17 §1): the INTERPRETER runs the entry file, so what the
  # image must hold is a plain Python script at the declared path — never
  # an executable, and never a host-interpreter shebang.
  #
  # The scripts are GENERATED from the installed pip's own metadata
  # (site-packages/pip-*.dist-info/entry_points.txt, the distribution's
  # SSOT for `pip = pip._internal.cli.main:main`) rather than copied from
  # the staged install's bin/: `make install`'s ensurepip writes the
  # build-tree interpreter as the shebang (a dead host path in any mounted
  # layout), and the msys leg runs ensurepip with ENSUREPIP=no (pip is
  # placed by PythonBuild#place_pip), so no staged script exists there at
  # all. Generating both legs from the same metadata keeps the inventory
  # identical across platforms and independent of ensurepip's install mode.
  #
  # The shebang names the in-image convention path (<mount_root>/bin/python3),
  # never a host interpreter. The two-artifact model ships the interpreter
  # BESIDE the image, so no in-image file can back the line either; the
  # driver-composed boot never reads it (the interpreter is already
  # running), and the spelling at least stays truthful about the mount the
  # image is built for.
  #
  # The inventory is the declared spawn surface: ImageManifest renders one
  # `provides.entrypoints` {name, path: /bin/<name>} per staged script,
  # and ImageBuilder::verify_spawn_surface asserts the two agree in both
  # directions (declared ⊆ staged, staged ⊆ declared).
  class ConsoleScripts
    # The pip command family the image exposes. Unversioned names only —
    # the ecosystem's runtime entrypoint convention (openjdk's java/javac,
    # truffleruby's ruby/gem): the versioned ensurepip aliases (pip3.13)
    # would add surface without a consumer, and every name here becomes a
    # shim `tebako install python:<name>` can register.
    NAMES = %w[pip pip3].freeze

    # The in-image interpreter spelling the shebang carries (see the class
    # comment: inert at boot, truthful about the mount).
    SHEBANG_INTERPRETER = "python3"

    def initialize(tree:, python_version:, mount_root:)
      @tree = tree
      @python = TebakoPythonBuilder::PythonVersion.new(python_version)
      @mount_root = mount_root
    end

    # Write one script per NAMES entry into the tree's bin/; returns the
    # staged names (sorted — the manifest's declaration order).
    def deploy
      bin = File.join(@tree, "bin")
      FileUtils.mkdir_p(bin)
      NAMES.sort.each do |name|
        path = File.join(bin, name)
        File.write(path, script_text(console_entry(name)))
        FileUtils.chmod(0o755, path)
      end
    end

    private

    # The console-script spec (`module:attr`) the installed pip declares
    # for `name`, read from its dist-info. Absent metadata is a named
    # build error: the image cannot declare a command whose entry it
    # cannot derive (never a hardcoded guess that drifts from the shipped
    # pip).
    def console_entry(name)
      path = entry_points_path
      text = File.read(path)
      section = nil
      text.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        if line.start_with?("[") && line.end_with?("]")
          section = line[1..-2]
          next
        end
        next unless section == "console_scripts"

        key, value = line.split("=", 2)
        next unless value && key.strip == name

        # An extras marker (`[foo]`) is install-time metadata, not part of
        # the entry callable.
        return value.strip.sub(/\s*\[.*\]\z/, "").strip
      end
      raise TebakoPythonBuilder::Error.new(
        "#{path} declares no [console_scripts] entry named '#{name}' — the env image's spawn " \
        "surface cannot be rendered from the installed pip", 105
      )
    end

    def entry_points_path
      pattern = File.join(@tree, "lib", @python.libdir_name, "site-packages", "pip-*.dist-info",
                          "entry_points.txt")
      candidates = Dir.glob(pattern)
      unless candidates.length == 1
        raise TebakoPythonBuilder::Error.new(
          "expected exactly one pip entry_points.txt under #{File.join(@tree, "lib", @python.libdir_name, "site-packages")} " \
          "(found #{candidates.length}) — the staged site-packages must carry pip with its dist-info", 105
        )
      end
      candidates.first
    end

    # distlib's console-script template (the shape pip itself installs),
    # with the in-image shebang. The `sys.argv[0]` scrub keeps pip's
    # program name stable whatever spelling the entry resolves through.
    def script_text(spec)
      module_name, attr = spec.split(":", 2)
      if module_name.nil? || attr.nil? || module_name.empty? || attr.empty?
        raise TebakoPythonBuilder::Error.new(
          "malformed console_scripts entry '#{spec}' in the installed pip — expected module:attr", 105
        )
      end
      import_name = attr.split(".").first
      <<~PY
        #!#{@mount_root}/bin/#{SHEBANG_INTERPRETER}
        # -*- coding: utf-8 -*-
        import re
        import sys
        from #{module_name} import #{import_name}
        if __name__ == '__main__':
            sys.argv[0] = re.sub(r'(-script\\.pyw|\\.exe)?$', '', sys.argv[0])
            sys.exit(#{attr}())
      PY
    end
  end
end
