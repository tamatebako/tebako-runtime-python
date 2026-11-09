# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe TebakoPythonBuilder::Contract do
  # The repo's own contract.yml must carry the macOS floor pin — the
  # floor is a product decision, never the runner image's accident
  # (tebako-runtime-python#81: v0.3.3 shipped arm64=14.8, x86_64=15.7).
  it "pins the macOS support floor as a well-formed major.minor" do
    expect(described_class.new.macos_deployment_target).to match(/^\d+\.\d+$/)
  end

  it "fails closed by name when the floor pin is absent" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "contract.yml")
      File.write(path, "contract_version: 2\npython:\n  catalog: []\n")
      expect { described_class.new(path).macos_deployment_target }
        .to raise_error(TebakoPythonBuilder::Error, /macos_deployment_target/)
    end
  end

  it "fails closed by name when the floor pin is empty" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "contract.yml")
      File.write(path, "contract_version: 2\nmacos_deployment_target: \"\"\npython:\n  catalog: []\n")
      expect { described_class.new(path).macos_deployment_target }
        .to raise_error(TebakoPythonBuilder::Error, /macos_deployment_target/)
    end
  end
end

RSpec.describe TebakoPythonBuilder::PythonBuild do
  let(:macos) { TebakoPythonBuilder::Platform.new("arm64-darwin23") }
  let(:linux) { TebakoPythonBuilder::Platform.new("x86_64-pc-linux-gnu") }

  def build(platform, floor)
    described_class.new(platform: platform, python_version: "3.14.7", prefix: "/p",
                        tarball: "/t.tar.gz", src_sha256: "00", link_unit: nil,
                        link_unit_dir: "/l", repo_root: "/r",
                        macos_deployment_target: floor)
  end

  it "carries the pinned floor as MACOSX_DEPLOYMENT_TARGET on macOS" do
    expect(build(macos, "14.0").floor_env).to eq("MACOSX_DEPLOYMENT_TARGET" => "14.0")
  end

  it "sets nothing off-macOS (the floor is a macOS decision)" do
    expect(build(linux, "14.0").floor_env).to eq({})
  end

  it "fails closed by name on macOS without a floor" do
    expect { build(macos, nil).floor_env }
      .to raise_error(TebakoPythonBuilder::Error, /macos_deployment_target/)
  end
end
