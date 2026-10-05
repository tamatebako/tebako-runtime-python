# frozen_string_literal: true

require "spec_helper"

require "yaml"

# The per-platform build workflow's structural locks. tebako#716's era gate
# (spec 05 §2's era law): the language segment of the package name is a
# COMPUTED output of the compute job, keyed on the run's own tebako version
# (never a repo-wide constant) so a mop-up rerun of a <= 0.2.x line keeps
# composing old-era names. Every compose site of the package name in the
# workflow threads that output — a site that drops the infix composes a name
# the gem's era-gated uploader/audit never expects, and vice versa. Locked
# here so a drift fails loudly.
RSpec.describe ".github/workflows/_build-platform.yml" do
  let(:workflow_path) { File.join(REPO_ROOT, ".github", "workflows", "_build-platform.yml") }
  let(:workflow) { YAML.load_file(workflow_path) }

  it "gates the package-name language segment on the run's tebako version (tebako#716)" do
    compute = workflow.fetch("jobs").fetch("compute")
    expect(compute.dig("outputs", "lang_infix")).to eq("${{ steps.emit.outputs.lang_infix }}")
    step = compute.fetch("steps").find { |s| s["id"] == "emit" }
    expect(step.fetch("run")).to include("cat VERSION", "0.3.0", "lang_infix=python-")
    text = File.read(workflow_path)
    compose = text.scan(/tebako-runtime-\$\{\{ needs\.compute\.outputs\.tebako_version \}\}-(.{0,70})/)
    expect(compose).not_to be_empty
    compose.flatten.each do |tail|
      expect(tail).to start_with("${{ needs.compute.outputs.lang_infix }}"),
                      "a tebako-runtime-<ver>- compose site does not thread the lang_infix output"
    end
  end
end
