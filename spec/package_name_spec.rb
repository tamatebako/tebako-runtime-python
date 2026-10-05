# frozen_string_literal: true

require "spec_helper"

# tebako#716's era gate (spec 05 §2's era law): the language segment of the
# runtime package name exists ONLY on tebako lines >= 0.3.0 — the <= 0.2.x
# lines are immutable (sha256-pinned in the live registries) and compose the
# lang-less spelling forever. PackageName is the gate's single owner; the
# builder's default output and the release adapter's lang_name both flow it.
RSpec.describe TebakoPythonBuilder::PackageName do
  it "declares no language segment on the immutable old-era lines" do
    expect(described_class.lang_segment("0.1.0")).to be_nil
    expect(described_class.lang_segment("0.2.7")).to be_nil
    expect(described_class.lang_infix("0.2.7")).to eq("")
  end

  it "declares the language segment from 0.3.0 on, boundary included" do
    expect(described_class.lang_segment("0.3.0")).to eq("python")
    expect(described_class.lang_infix("0.3.0")).to eq("python-")
    expect(described_class.lang_segment("0.3.1")).to eq("python")
    expect(described_class.lang_segment("1.0.0")).to eq("python")
  end

  it "compares versions numerically, never lexically" do
    # "0.10.0" sorts after "0.3.0" numerically but before it lexically.
    expect(described_class.lang_segment("0.10.0")).to eq("python")
    expect(described_class.lang_segment("0.2.10")).to be_nil
  end

  it "fails named on a malformed version (never a silent old-era fallback)" do
    expect { described_class.lang_segment("not-a-version") }.to raise_error(ArgumentError)
  end
end
