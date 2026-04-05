class ImmichAccelerator < Formula
  desc "Run Immich compute natively on Apple Silicon"
  homepage "https://github.com/epheterson/immich-apple-silicon"
  url "https://github.com/epheterson/immich-apple-silicon/archive/refs/tags/v1.3.0.tar.gz"
  sha256 "ce76f30fec37f1a44e6557729481dbad4da6daa354d1ca377bf6fffc19305aa1"
  license "MIT"

  # ML service submodule (not included in GitHub's auto-generated tarball)
  resource "ml" do
    url "https://github.com/epheterson/immich-ml-metal/archive/00640a40ced11084cf987cff6f0db7863f35c402.tar.gz"
    sha256 "0d17fdfac24cbfbbd761a6667c2ac5fa336338afec34bdf45183f6f7c20769dd"
  end

  depends_on :macos
  depends_on arch: :arm64
  depends_on "node"
  depends_on "vips"
  depends_on "python@3.11"

  def install
    # Install the main package
    libexec.install Dir["*"]

    # Install ML submodule into ml/
    resource("ml").stage do
      (libexec/"ml").install Dir["*"]
    end

    # Create ML venv
    ml_dir = libexec/"ml"
    system Formula["python@3.11"].opt_bin/"python3.11", "-m", "venv", ml_dir/"venv"
    system ml_dir/"venv/bin/pip", "install", "-r", ml_dir/"requirements.txt"

    # Create wrapper script
    (bin/"immich-accelerator").write <<~SH
      #!/bin/bash
      export PYTHONPATH="#{libexec}:$PYTHONPATH"
      cd "#{libexec}"
      exec "#{Formula["python@3.11"].opt_bin}/python3.11" -m immich_accelerator "$@"
    SH
  end

  def caveats
    <<~EOS
      To get started:
        immich-accelerator setup

      This will detect your Immich instance, configure everything,
      and offer to start services + install auto-launch on login.
    EOS
  end

  service do
    run [bin/"immich-accelerator", "watch"]
    keep_alive true
    log_path var/"log/immich-accelerator.log"
    error_log_path var/"log/immich-accelerator-error.log"
  end

  test do
    assert_match "immich-accelerator", shell_output("#{bin}/immich-accelerator --version")
  end
end
