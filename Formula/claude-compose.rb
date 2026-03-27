# Note: This is a reference copy. The official formula is in the nersonSwift/homebrew-tap repo.
class ClaudeCompose < Formula
  desc "Multi-project workspace launcher for Claude Code"
  homepage "https://github.com/nersonSwift/claude-compose"
  url "https://github.com/nersonSwift/claude-compose/archive/refs/tags/v#{version}.tar.gz"
  sha256 ""  # Updated by release workflow
  license "MIT"

  depends_on "jq"

  def install
    system "make"
    bin.install "claude-compose"
  end

  test do
    assert_match "claude-compose v#{version}", shell_output("#{bin}/claude-compose --version")
  end
end
