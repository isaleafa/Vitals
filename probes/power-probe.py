#!/usr/bin/env python3
"""Mac 电源/充电遥测探测脚本（工具箱 M0：数据源验证）

把参考面板（PowerMaster 那种）要用的每一栏字段读出来。
全部只读、无需 root、无需任何第三方库。

用法:
    python3 power-probe.py             # 打印一次全部字段
    python3 power-probe.py --json      # 输出 JSON（喂前端 / 存历史）
    python3 power-probe.py --watch 5   # 每 5 秒刷新（Ctrl-C 退出）

数据来源:
    ioreg -rn AppleSmartBattery -a        电池 / 适配器 / 功率遥测（plist 直接可解析）
    ioreg -a -l -w0 -c AppleHPMInterface  USB-C PD 对端身份（VID/PID/PD 规范版本）
                                          注意：这棵树约 20MB，首解 1~2 秒，脚本内已做缓存
    system_profiler -json SPPowerDataType 官方口径的循环次数 / 健康度
"""
import argparse
import json
import plistlib
import subprocess
import time

_pd_cache = {"t": 0.0, "v": []}


def _ioreg_plist(*args):
    raw = subprocess.run(["ioreg", "-a", "-l", "-w0", *args], capture_output=True).stdout
    return plistlib.loads(raw) if raw else None


def battery_node():
    return plistlib.loads(
        subprocess.run(["ioreg", "-rn", "AppleSmartBattery", "-a"], capture_output=True).stdout
    )[0]


def pd_identity(max_age=60):
    """USB-C 口上 PD 对端（SOP）的身份：厂商 VID / 产品 PID / PD 规范版本。"""
    if time.time() - _pd_cache["t"] < max_age:
        return _pd_cache["v"]
    found = []
    tree = _ioreg_plist("-c", "AppleHPMInterface")
    if tree is None:
        tree = []

    def walk(n):
        if isinstance(n, dict):
            if str(n.get("IOObjectClass", "")).endswith("USBPDSOP"):
                found.append(
                    {
                        "端口": n.get("ParentBuiltInPortNumber"),
                        "VendorID": n.get("Vendor ID"),
                        "ProductID": n.get("Product ID"),
                        "PD规范版本": n.get("Specification Revision"),
                        "VDO数": (n.get("Metadata") or {}).get("VDO Count"),
                    }
                )
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for x in n:
                walk(x)

    walk(tree)
    _pd_cache.update(t=time.time(), v=found)
    return found


def official_health():
    """macOS 官方口径：循环次数 / 最大容量 / 健康评级。"""
    raw = subprocess.run(
        ["system_profiler", "-json", "SPPowerDataType"], capture_output=True
    ).stdout
    try:
        d = json.loads(raw or "{}")
    except ValueError:
        return {}
    for item in d.get("SPPowerDataType", []):
        if "sppower_battery_health_info" in item:
            return item["sppower_battery_health_info"]
    return {}


def snapshot():
    b = battery_node()
    ad = b.get("AdapterDetails") or {}
    pt = b.get("PowerTelemetryData") or {}
    bd = b.get("BatteryData") or {}
    active = ad.get("UsbHvcHvcIndex")
    gears = [
        {
            "档位": "%gV / %.2fA" % (g["MaxVoltage"] / 1000, g["MaxCurrent"] / 1000),
            "功率W": round(g["MaxVoltage"] * g["MaxCurrent"] / 1e6, 1),
            "当前": i == active,
        }
        for i, g in enumerate(ad.get("UsbHvcMenu") or [])
    ]
    design = bd.get("DesignCapacity") or 0
    health = (
        round(bd.get("FullChargeCapacity", 0) / design * 100, 1) if design else None
    )
    return {
        "充电状态": "已接通电源" if b.get("ExternalConnected") else "未接通",
        "正在充电": bool(b.get("IsCharging")),
        "电量%": b.get("CurrentCapacity"),
        "输入电压V": round(pt.get("SystemVoltageIn", 0) / 1000, 2),
        "输入电流mA": pt.get("SystemCurrentIn"),
        "输入功率W": round(pt.get("SystemPowerIn", 0) / 1000, 2),
        "循环次数": b.get("CycleCount"),
        "健康度_自算%": health,
        "健康度_官方": official_health() or "不可用",
        "适配器额定W": ad.get("Watts"),
        "当前档位": (
            "%gV / %.2fA" % (ad["AdapterVoltage"] / 1000, ad["Current"] / 1000)
            if ad.get("AdapterVoltage")
            else None
        ),
        "支持档位": gears,
        "PD身份": pd_identity(),
        "电池序列号": b.get("Serial"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--watch", type=float, metavar="SEC", help="每 SEC 秒刷新")
    a = ap.parse_args()
    while True:
        s = snapshot()
        if a.json:
            print(json.dumps(s, ensure_ascii=False, indent=1))
        else:
            for k, v in s.items():
                if isinstance(v, list):
                    print("%s:" % k)
                    for x in v:
                        print("    ", json.dumps(x, ensure_ascii=False))
                else:
                    print("%-12s %s" % (k, v))
        if not a.watch:
            break
        time.sleep(a.watch)


if __name__ == "__main__":
    main()
