import CoreWLAN
import Foundation

/// Wi-Fi 无线射频链路状态
struct WiFiStats: Codable {
    var interfaceName: String
    var ssid: String?
    var rssi: Int              // 信号强度 dBm（例如 -50）
    var noise: Int             // 噪声基底 dBm（例如 -91）
    var snr: Int               // 信噪比 dB = rssi - noise（例如 41）
    var txRate: Double         // 协商物理速率 Mbps（例如 292.0）
    var channel: Int           // 信道编号（例如 153）
    var band: String           // "2.4 GHz" / "5 GHz" / "6 GHz"
    var channelWidth: String   // "20 MHz" / "40 MHz" / "80 MHz" / "160 MHz"
    var quality: String        // "极佳" / "良好" / "一般" / "较差"

    var rssiText: String { "\(rssi) dBm" }
    var noiseText: String { "\(noise) dBm" }
    var snrText: String { "\(snr) dB" }
    var txRateText: String { String(format: "%.0f Mbps", txRate) }
    var channelSummary: String { "信道 \(channel) · \(band) · \(channelWidth)" }
}

enum WiFiProvider {
    /// 读取当前 Wi-Fi 射频状态（原生 CoreWLAN，免 root，耗时约 3~4ms）
    static func read() -> WiFiStats? {
        guard let iface = CWWiFiClient.shared().interface(),
              let name = iface.interfaceName,
              iface.powerOn() else {
            return nil
        }

        let rssi = iface.rssiValue()
        // 未连上 Wi-Fi 时 rssi 常见为 0
        guard rssi != 0 else { return nil }

        let noise = iface.noiseMeasurement()
        let snr = rssi - noise
        let txRate = iface.transmitRate()

        var channelNum = 0
        var bandStr = "—"
        var widthStr = "—"

        if let ch = iface.wlanChannel() {
            channelNum = Int(ch.channelNumber)
            switch ch.channelBand {
            case .band2GHz: bandStr = "2.4 GHz"
            case .band5GHz: bandStr = "5 GHz"
            case .band6GHz: bandStr = "6 GHz"
            case .bandUnknown: bandStr = "未知频段"
            @unknown default: bandStr = "未知频段"
            }
            switch ch.channelWidth {
            case .width20MHz: widthStr = "20 MHz"
            case .width40MHz: widthStr = "40 MHz"
            case .width80MHz: widthStr = "80 MHz"
            case .width160MHz: widthStr = "160 MHz"
            case .widthUnknown: widthStr = "—"
            @unknown default: widthStr = "—"
            }
        }

        let quality: String
        if snr >= 35 { quality = "极佳" }
        else if snr >= 25 { quality = "良好" }
        else if snr >= 15 { quality = "一般" }
        else { quality = "较弱" }

        // SSID 在 macOS 14+ 若无定位权限会返回 nil，但所有射频指标均免权限正常读取
        let ssid = iface.ssid()

        return WiFiStats(
            interfaceName: name,
            ssid: (ssid?.isEmpty == false) ? ssid : nil,
            rssi: rssi,
            noise: noise,
            snr: snr,
            txRate: txRate,
            channel: channelNum,
            band: bandStr,
            channelWidth: widthStr,
            quality: quality
        )
    }
}
