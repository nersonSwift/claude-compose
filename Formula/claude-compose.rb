class ClaudeCompose < Formula
  desc "Multi-project launcher for Claude Code — merge MCP, permissions, skills, agents across projects"
  homepage "https://github.com/nersonSwift/claude-compose"
  url "https://github.com/nersonSwift/claude-compose/archive/refs/tags/v1.1.1.tar.gz"
  sha256 ""  # Updated by release workflow
  license "MIT"

  depends_on "jq"

  def install
    bin.install "claude-compose"
  end

  test do
    assert_match "claude-compose v#{version}", shell_output("#{bin}/claude-compose --version")
  end
end
