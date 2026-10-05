# frozen_string_literal: true

require "spec_helper"

# Builder#default_output is the era gate's compose-side consumer
# (tebako#716): the local-build package name carries the language segment
# exactly when the build's tebako version is a >= 0.3.0 line — PackageName
# owns the gate itself (package_name_spec.rb); here the wiring is locked.
RSpec.describe TebakoPythonBuilder::Builder do
  def builder(tebako_version)
    described_class.new(repo_root: REPO_ROOT, python_version: "3.13.15", tebako_version: tebako_version,
                        prefix: File.join(Dir.pwd, ".build"), output: nil,
                        src_release: "v0.0.0", link_unit_release: "v0.0.0")
  end

  it "composes the language segment into the default package name on a >= 0.3.0 line" do
    expect(File.basename(builder("0.3.0").default_output))
      .to match(/\Atebako-runtime-0\.3\.0-python-3\.13\.15-.+(\.exe)?\z/)
  end

  it "composes the lang-less default name for a <= 0.2.x line (the immutable era)" do
    name = File.basename(builder("0.2.7").default_output)
    expect(name).to match(/\Atebako-runtime-0\.2\.7-3\.13\.15-.+(\.exe)?\z/)
    expect(name).not_to include("python-3.13.15")
  end
end
