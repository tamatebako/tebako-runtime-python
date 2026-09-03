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

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "uri"

module TebakoPythonBuilder
  # Build helpers (tebako-runtime-ruby's BuildHelpers plus the shared
  # download core every fetcher uses — SourceFetcher, LinkUnit, TfsTool —
  # so the Net::HTTP discipline (redirect bound, timeouts, named failures)
  # exists exactly once).
  module BuildHelpers
    MAX_REDIRECTS = 5

    class << self
      def run_with_capture(args, env: {}, chdir: nil)
        args = args.compact
        puts "   ... @ #{args.join(" ")}"
        spawn_opts = chdir ? { chdir: chdir } : {}
        out, st = Open3.capture2e(env, *args, **spawn_opts)
        if st.signaled? || !st.exitstatus.zero?
          raise TebakoPythonBuilder::Error, "Failed to run #{args.join(" ")} (#{st}):\n #{out}"
        end

        out
      end

      def run_with_capture_v(args, env: {}, chdir: nil)
        if verbose?
          args_v = args.dup
          args_v.push("--verbose")
          puts run_with_capture(args_v, env: env, chdir: chdir)
        else
          run_with_capture(args, env: env, chdir: chdir)
        end
      end

      # Sets up temporary environment variables and yields to the
      # block. When the block exits, the environment variables are set
      # back to their original values.
      def with_env(hash)
        old = {}
        hash.each do |k, v|
          old[k] = ENV.fetch(k, nil)
          ENV[k] = v
        end
        begin
          yield
        ensure
          hash.each_key { |k| ENV[k] = old[k] }
        end
      end

      def verbose?
        %w[yes true].include?(ENV.fetch("VERBOSE", nil))
      end

      def sha256_file(path)
        Digest::SHA256.file(path).hexdigest
      end

      # Download url to dest (creating the parent dir); a failure deletes
      # the partial file and raises with the caller's exit code.
      def download(url, dest, code:)
        FileUtils.mkdir_p(File.dirname(dest))
        File.binwrite(dest, read_url(url, code: code))
        dest
      rescue TebakoPythonBuilder::Error
        FileUtils.rm_f(dest)
        raise
      end

      def read_url(url, code:, redirects_left: MAX_REDIRECTS, headers: {}) # rubocop:disable Metrics/MethodLength
        uri = URI.parse(url)
        return read_file_url(uri, code) if uri.scheme == "file"
        if redirects_left.zero?
          raise TebakoPythonBuilder::Error.new("too many redirects fetching #{url}", code)
        end

        response = http_get(uri, headers)
        case response
        when Net::HTTPSuccess then response.body
        when Net::HTTPRedirection
          read_url(URI.join(url, response["location"]).to_s, code: code,
                   redirects_left: redirects_left - 1, headers: headers)
        else
          raise TebakoPythonBuilder::Error.new("#{response.code} #{response.message} fetching #{url}", code)
        end
      end

      def read_file_url(uri, code)
        # RFC 8089: a Windows drive letter rides the file URL path as
        # /D:/...; a mingw/ucrt ruby needs D:/... (the slashed form is
        # EINVAL to File.binread). This is URL decoding, not a fallback.
        path = uri.path.sub(%r{\A/([A-Za-z]:/)}, '\1')
        File.binread(path)
      rescue Errno::ENOENT
        raise TebakoPythonBuilder::Error.new("not found: #{path}", code)
      end

      def http_get(uri, headers = {})
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 15
        http.read_timeout = 600
        http.start do |session|
          session.get(uri.request_uri.empty? ? "/" : uri.request_uri, headers)
        end
      end

      # The GitHub release API's per-asset digest map for a tag:
      # { asset_name => "<sha256 hex>" }. The release API's digest field is
      # the link-unit's trust anchor (tebako-runtime-ruby
      # ci/link-unit-download.sh): the release SHA256SUMS does not cover
      # the link-unit assets. GITHUB_TOKEN/GH_TOKEN, when present, rides
      # the request (CI rate limits); the release is public, so an
      # unauthenticated read works at interactive rates.
      def release_asset_digests(repo, tag, code:) # rubocop:disable Metrics/MethodLength
        url = "https://api.github.com/repos/#{repo}/releases/tags/#{tag}"
        headers = { "Accept" => "application/vnd.github+json" }
        token = ENV.fetch("GITHUB_TOKEN", nil) || ENV.fetch("GH_TOKEN", nil)
        headers["Authorization"] = "Bearer #{token}" if token && !token.empty?

        data = JSON.parse(read_url(url, code: code, headers: headers))
        (data["assets"] || []).each_with_object({}) do |asset, acc|
          digest = asset["digest"].to_s
          acc[asset["name"]] = digest.delete_prefix("sha256:") if digest.start_with?("sha256:")
        end
      rescue JSON::ParserError => e
        raise TebakoPythonBuilder::Error.new("unparseable release API response for #{repo}@#{tag}: #{e.message}", code)
      end
    end
  end
end
