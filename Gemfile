# frozen_string_literal: true

source "https://rubygems.org"

require "yaml"

# contract.yml schema validation (scripts/check_contract.rb).
gem "json_schemer", "~> 2.4"

# The release machinery — the legs' publish/sign jobs and the publish.yml
# coordinator's audit. tamatebako/tebako-release-tooling is the single
# owner (ecosystem invariant 10); the pin lives in contract.yml's
# release_tooling so the bump is one contract edit, never a second
# hand-written copy of the machinery.
gem "tebako-release",
    git: "https://github.com/tamatebako/tebako-release-tooling.git",
    tag: YAML.load_file(File.expand_path("contract.yml", __dir__)).fetch("release_tooling")

# The registry render (tools/registry_update.rb — the coordinator's
# release job) talks to the releases API directly.
gem "octokit", "~> 7.1"

# octokit 7.x requires base64 without declaring it; a default gem on the
# CI ruby (3.3) but bundled-gems-only on 3.4+ hosts (the maintainer's
# local ruby), where the undeclared require LoadErrors.
gem "base64", "~> 0.2"

# The spec suite (tebako-runtime-ruby's Gemfile is the model).
group :development, :test do
  gem "rspec", "~> 3.13"
end
