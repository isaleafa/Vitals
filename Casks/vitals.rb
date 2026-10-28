cask "vitals" do
  version "0.2.3"
  sha256 "b52dab35ac9ed40bfa4b4fc97775fd5b8c3c0022298032dd24e83ee36541b52a"

  url "https://github.com/isaleafa/Vitals/releases/download/v#{version}/Vitals-#{version}.dmg"
  name "Vitals"
  desc "轻量级 macOS 菜单栏性能与网络监控工具箱"
  homepage "https://github.com/isaleafa/Vitals"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Vitals.app"

  postflight do
    # 移除隔离属性，避免 ad-hoc 签名触发 Gatekeeper 拦截
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Vitals.app"],
                   sudo: false
  end

  uninstall quit: "top.liyi830.vitals"

  zap trash: [
    "~/Library/Preferences/top.liyi830.vitals.plist",
  ]
end
