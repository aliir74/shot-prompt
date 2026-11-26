# Homebrew cask, published from the aliir74/homebrew-tap repo:
#   brew install --cask aliir74/tap/shotprompt
# Each release attaches this cask with its version and sha256 filled in
# (shotprompt.rb); copy that file to the tap. The values here are placeholders.
cask "shotprompt" do
  version "0.4.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/aliir74/shot-prompt/releases/download/v#{version}/ShotPrompt-#{version}.dmg"
  name "ShotPrompt"
  desc "Screenshot, type a prompt, send it to Claude Code, Codex, Cursor or ChatGPT"
  homepage "https://github.com/aliir74/shot-prompt"

  depends_on macos: ">= :ventura"

  app "ShotPrompt.app"

  uninstall quit:       "io.github.aliir74.shot-prompt",
            login_item: "ShotPrompt"

  zap trash: [
    "~/Library/Caches/ShotPrompt",
    "~/Library/Preferences/io.github.aliir74.shot-prompt.plist",
  ]
end
