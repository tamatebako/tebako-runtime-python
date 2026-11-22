# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# FactoryPatches (patches/README.md's contract): the selection grammar
# (msys + the line's dir + the _msys suffix), the content fingerprint,
# and the git-apply state machine — apply on a clean tree, the loud
# already-present skip on a carried one, the named refusal on drift.
RSpec.describe TebakoPythonBuilder::FactoryPatches do
  def platform(ostype, arch = "x86_64")
    TebakoPythonBuilder::Platform.new(ostype, arch)
  end

  def set_for(ostype, version = "3.14.7", root: REPO_ROOT)
    described_class.new(platform: platform(ostype), python_version: version, repo_root: root)
  end

  it "is empty off msys even for the patched line (POSIX autoconf exports sem_unlink by construction)" do
    expect(set_for("aarch64-apple-darwin24").paths).to eq([])
    expect(set_for("x86_64-linux-gnu").paths).to eq([])
  end

  it "carries the 3.14 sem_unlink port on msys, sorted by name" do
    names = set_for("x86_64-w64-mingw32").paths.map { |path| File.basename(path) }
    expect(names).to eq(%w[multiprocessing_sem_unlink_msys.patch])
  end

  it "is empty for an msys line with no factory patch dir" do
    expect(set_for("x86_64-w64-mingw32", "3.13.15").paths).to eq([])
  end

  it "fingerprints the empty set as \"\" and the carried set as a stable content key" do
    expect(set_for("aarch64-apple-darwin24").fingerprint).to eq("")
    fingerprint = set_for("x86_64-w64-mingw32").fingerprint
    expect(fingerprint).to match(/\A[0-9a-f]{64}\z/)
    expect(set_for("x86_64-w64-mingw32").fingerprint).to eq(fingerprint)
  end

  it "applies the empty set as a no-op" do
    expect { set_for("aarch64-apple-darwin24").apply(Dir.pwd) }.not_to raise_error
  end

  describe "#apply with a patch set" do
    # A scratch repo (patches/3.14/demo_msys.patch) and a scratch source
    # tree carrying the patch's pre-image.
    let(:root) { Dir.mktmpdir("factory-patches-root") }
    let(:tree) { Dir.mktmpdir("factory-patches-tree") }
    let(:patch_file) { File.join(root, "patches", "3.14", "demo_msys.patch") }
    let(:target) { File.join(tree, "demo.c") }

    before do
      FileUtils.mkdir_p(File.dirname(patch_file))
      File.write(target, "int before;\nint anchor;\n")
      File.write(patch_file, <<~PATCH)
        diff --git a/demo.c b/demo.c
        index 0000000..1111111 100644
        --- a/demo.c
        +++ b/demo.c
        @@ -1,2 +1,2 @@
        -int before;
        +int after;
         int anchor;
      PATCH
    end

    after do
      FileUtils.rm_rf(root, secure: true)
      FileUtils.rm_rf(tree, secure: true)
    end

    def msys_set(root)
      described_class.new(platform: platform("x86_64-w64-mingw32"),
                          python_version: "3.14.7", repo_root: root)
    end

    it "applies the set to a clean tree, then detects the carried state on a re-run" do
      msys_set(root).apply(tree)
      expect(File.read(target)).to eq("int after;\nint anchor;\n")
      expect { msys_set(root).apply(tree) }.to output(/already present/).to_stdout
      expect(File.read(target)).to eq("int after;\nint anchor;\n")
    end

    it "refuses a drifted tree with the named exit code (108)" do
      File.write(target, "int unrelated;\n")
      expect { msys_set(root).apply(tree) }
        .to raise_error(TebakoPythonBuilder::Error) { |error| expect(error.error_code).to eq(108) }
    end
  end
end
