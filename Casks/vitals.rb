cask "vitals" do
  version "0.2.2"
  sha256 "8466fe741ba54f179f3dc95871145525415319a748346f411ebff794751c3320"

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
