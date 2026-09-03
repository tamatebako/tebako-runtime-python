# frozen_string_literal: true

source "https://rubygems.org"

# contract.yml schema validation (scripts/check_contract.rb).
gem "json_schemer", "~> 2.4"

# The release pipeline (scripts/upload_release.rb — the publish.yml
# coordinator's release job). The pin matches tebako-runtime-ruby's.
gem "octokit", "~> 7.1"

# octokit 7.x requires base64 without declaring it; a default gem on the
# CI ruby (3.3) but bundled-gems-only on 3.4+ hosts (the maintainer's
# local ruby), where the undeclared require LoadErrors.
gem "base64", "~> 0.2"

# The spec suite (boot-contract parity, matrix planner, builder model)
# remains a TODO.python/02 follow-up — rspec/rubocop join this file in
# the same PR (tebako-runtime-ruby's Gemfile is the model).
