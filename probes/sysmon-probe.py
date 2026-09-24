#!/usr/bin/env python3
"""Mac 实时系统监视探测脚本（工具箱 M0 扩展版：CPU / 内存 / 磁盘 / 网络）

只用 Python 标准库；全部走底层计数器（不启动慢命令，全量采样 ~0.1 秒）。
用法:
    python3 sysmon-probe.py              # 打印一次快照（内部采样 1 秒算速率）
    python3 sysmon-probe.py --watch 1    # 每 1 秒原地刷新
    python3 sysmon-probe.py --watch 1 --count 5   # 只刷 5 次（便于测试/脚本）
    python3 sysmon-probe.py --json       # 输出 JSON
    python3 sysmon-probe.py --top        # 附带 CPU/内存占用最高的进程
    python3 sysmon-probe.py --smart      # 附带 SSD SMART 摘要（smartctl，无需 sudo）
    python3 sysmon-probe.py --net        # 附带接口详情（IP/CIDR/MAC/流量）+ IPv4 路由表
    python3 sysmon-probe.py --net --net6 # 路由表附带 IPv6
    python3 sysmon-probe.py --net --net-all   # 接口列表包含休眠接口

数据来源（原生 App 里的对应做法）:
    CPU      host_processor_info()             → 同款 Mach API
    内存     vm_stat 解析                      → host_statistics64 / vm_statistics64_data_t
    磁盘容量 statvfs                           → URLResourceValues
    磁盘 IO  IOKit IOBlockStorageDriver 累计计数器（ioreg 读取）
    网络      getifaddrs + struct if_data 计数器（32 位，速率计算时处理回绕）
    网络地址  getifaddrs 的 AF_INET/AF_INET6 项（netmask 数位 = 前缀长度）
    路由表    netstat -rn（本机 6ms）           → sysctl NET_RT_DUMP (PF_ROUTE)
    温度/功耗 无公开接口：powermetrics（需 root）或 IOReport/IOHIDEventSystem 私有接口（参考 macmon/Stats）
"""
import argparse
import ctypes
import json
import os
import re
import subprocess
import sys
import time

CPU_STATE_MAX = 4
PROCESSOR_CPU_LOAD_INFO = 2
AF_LINK = 18
U32 = 0xFFFFFFFF

_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
_libc.mach_host_self.restype = ctypes.c_uint
_libc.mach_task_self.restype = ctypes.c_uint
_libc.vm_deallocate.argtypes = [ctypes.c_uint, ctypes.c_void_p, ctypes.c_uint]
_libc.vm_deallocate.restype = ctypes.c_int


def _run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


# ── CPU ────────────────────────────────────────────────────────────────
def cpu_ticks():
    """每核 [user, system, idle, nice] 累计 tick（Mach API，无需 root）。"""
    host = _libc.mach_host_self()
    count = ctypes.c_uint(0)
    info = ctypes.POINTER(ctypes.c_uint)()
    info_cnt = ctypes.c_uint(0)
    kr = _libc.host_processor_info(
        ctypes.c_uint(host),
        ctypes.c_int(PROCESSOR_CPU_LOAD_INFO),
        ctypes.byref(count),
        ctypes.byref(info),
        ctypes.byref(info_cnt),
    )
    if kr != 0:
        raise OSError("host_processor_info 失败，kern_return=%d" % kr)
    data = [
        [info[i * CPU_STATE_MAX + j] for j in range(CPU_STATE_MAX)]
        for i in range(count.value)
    ]
    _libc.vm_deallocate(
        _libc.mach_task_self(), ctypes.cast(info, ctypes.c_void_p), info_cnt.value * 4
    )
    return data


# ── 内存 ──────────────────────────────────────────────────────────────
def memory_pages():
    out = _run("vm_stat")
    page = int(re.search(r"page size of (\d+)", out).group(1))

    def g(key):
        m = re.search(re.escape(key) + r":\s+(\d+)", out)
        return int(m.group(1)) * page if m else 0

    return {
        "page": page,
        "wired": g("Pages wired down"),
        "active": g("Pages active"),
        "inactive": g("Pages inactive"),
        "free": g("Pages free"),
        "purgeable": g("Pages purgeable"),
        "compressor": g("Pages occupied by compressor"),
    }


# ── 网络（getifaddrs，替代很慢的 netstat -ib）────────────────────────
class _sockaddr(ctypes.Structure):
    _fields_ = [
        ("sa_len", ctypes.c_ubyte),
        ("sa_family", ctypes.c_ubyte),
        ("sa_data", ctypes.c_ubyte * 26),  # 要装得下 sockaddr_in6（28 字节）
    ]


class _ifaddrs(ctypes.Structure):
    pass


_ifaddrs._fields_ = [
    ("ifa_next", ctypes.POINTER(_ifaddrs)),
    ("ifa_name", ctypes.c_char_p),
    ("ifa_flags", ctypes.c_uint),
    ("ifa_addr", ctypes.POINTER(_sockaddr)),
    ("ifa_netmask", ctypes.POINTER(_sockaddr)),
    ("ifa_dstaddr", ctypes.POINTER(_sockaddr)),
    ("ifa_data", ctypes.c_void_p),
]

_libc.getifaddrs.argtypes = [ctypes.POINTER(ctypes.POINTER(_ifaddrs))]
_libc.freeifaddrs.argtypes = [ctypes.POINTER(_ifaddrs)]


class _if_data32(ctypes.Structure):
    """macOS <net/if_var.h> 的 struct if_data（32 位计数器版本）。"""

    _fields_ = [
        ("ifi_type", ctypes.c_ubyte), ("ifi_typelen", ctypes.c_ubyte),
        ("ifi_physical", ctypes.c_ubyte), ("ifi_addrlen", ctypes.c_ubyte),
        ("ifi_hdrlen", ctypes.c_ubyte), ("ifi_recvquota", ctypes.c_ubyte),
        ("ifi_xmitquota", ctypes.c_ubyte), ("ifi_unused1", ctypes.c_ubyte),
        ("ifi_mtu", ctypes.c_uint32), ("ifi_metric", ctypes.c_uint32),
        ("ifi_baudrate", ctypes.c_uint32),
        ("ifi_ipackets", ctypes.c_uint32), ("ifi_ierrors", ctypes.c_uint32),
        ("ifi_opackets", ctypes.c_uint32), ("ifi_oerrors", ctypes.c_uint32),
        ("ifi_collisions", ctypes.c_uint32),
        ("ifi_ibytes", ctypes.c_uint32), ("ifi_obytes", ctypes.c_uint32),
    ]


def net_counters():
    ptr = ctypes.POINTER(_ifaddrs)()
    if _libc.getifaddrs(ctypes.byref(ptr)) != 0:
        return {}
    out = {}
    try:
        p = ptr
        while p:
            e = p.contents
            if e.ifa_addr and e.ifa_addr.contents.sa_family == AF_LINK and e.ifa_data:
                d = ctypes.cast(e.ifa_data, ctypes.POINTER(_if_data32)).contents
                out[e.ifa_name.decode()] = {"in": d.ifi_ibytes, "out": d.ifi_obytes}
            p = e.ifa_next
    finally:
        _libc.freeifaddrs(ptr)
    return out


# ── 网络：接口详情 + 路由表 ──────────────────────────────────────────
AF_INET = 2
AF_INET6 = 30
IFF_UP, IFF_RUNNING, IFF_LOOPBACK, IFF_POINTOPOINT, IFF_BROADCAST = 0x1, 0x40, 0x8, 0x10, 0x2


def _ipv4(sa):
    return "%d.%d.%d.%d" % tuple(sa[4:8])


def _mask4_bits(sa):
    return sum(bin(b).count("1") for b in sa[4:8])


def _fmt_v6(b16):
    g = ["%x" % int.from_bytes(b16[i:i + 2], "big") for i in range(0, 16, 2)]
    best_i = best_len = 0
    i = 0
    while i < 8:
        if g[i] == "0":
            j = i
            while j < 8 and g[j] == "0":
                j += 1
            if j - i > best_len:
                best_i, best_len = i, j - i
            i = j
        else:
            i += 1
    if best_len > 1:
        return ":".join(g[:best_i]) + "::" + ":".join(g[best_i + best_len:])
    return ":".join(g)


def net_detail(prev_net=None, all_ifaces=False):
    """接口详情：状态 / MTU / IP(CIDR) / MAC / 累计流量（有上一帧时附实时速率）。
    默认只留有 IPv4 地址、或累计流量 ≥1MB 的接口（睡着的 utun/gif/anpi 等不显示）。"""
    ptr = ctypes.POINTER(_ifaddrs)()
    if _libc.getifaddrs(ctypes.byref(ptr)) != 0:
        return {}
    ifaces = {}
    try:
        p = ptr
        while p:
            e = p.contents
            name = e.ifa_name.decode()
            rec = ifaces.setdefault(name, {
                "flags": e.ifa_flags, "mtu": None, "v4": [], "v6": [],
                "mac": None, "counters": None, "rate": None,
            })
            raw = bytes(e.ifa_addr.contents) if e.ifa_addr else b""
            fam = raw[1] if raw else 0
            if fam == AF_LINK and e.ifa_data:
                d = ctypes.cast(e.ifa_data, ctypes.POINTER(_if_data32)).contents
                rec["counters"] = {"in": d.ifi_ibytes, "out": d.ifi_obytes}
                rec["mtu"] = d.ifi_mtu
                nlen, alen = raw[5], raw[6]
                if alen:
                    rec["mac"] = ":".join("%02x" % b for b in raw[8 + nlen:8 + nlen + alen])
            elif fam == AF_INET:
                nm = bytes(e.ifa_netmask.contents) if e.ifa_netmask else b""
                rec["v4"].append("%s/%d" % (_ipv4(raw), _mask4_bits(nm) if nm else 32))
            elif fam == AF_INET6:
                nm = bytes(e.ifa_netmask.contents) if e.ifa_netmask else b""
                plen = sum(bin(b).count("1") for b in nm[8:24]) if nm else 0
                rec["v6"].append("%s/%d" % (_fmt_v6(raw[8:24]), plen))
            p = e.ifa_next
    finally:
        _libc.freeifaddrs(ptr)
    for name, rec in ifaces.items():
        c = rec["counters"]
        if c and prev_net and name in prev_net:
            pv = prev_net[name]
            rec["rate"] = ((c["in"] - pv["in"]) & U32, (c["out"] - pv["out"]) & U32)
    if not all_ifaces:
        ifaces = {
            n: r for n, r in ifaces.items()
            if r["v4"] or (r["counters"] and sum(r["counters"].values()) >= 1_000_000)
        }
    return ifaces


def _norm_cidr4(tok):
    """netstat 简写 → 完整 CIDR：10.0.0/17 → 10.0.0.0/17；192.168.1.50 → /32；127 → /8。"""
    if "/" in tok:
        addr, plen = tok.split("/")
        plen = int(plen)
    else:
        addr, plen = tok, None
    parts = [int(x) for x in addr.split(".")]
    if plen is None:
        if len(parts) == 4:
            plen = 32                      # 四段无前缀 = 主机路由
        else:
            plen = 8 if parts[0] < 128 else 16 if parts[0] < 192 else 24
    parts += [0] * (4 - len(parts))
    val = 0
    for x in parts:
        val = (val << 8) | (x & 0xFF)
    if plen:
        val &= (0xFFFFFFFF << (32 - plen)) & 0xFFFFFFFF
    return "%d.%d.%d.%d/%d" % (val >> 24 & 0xFF, val >> 16 & 0xFF, val >> 8 & 0xFF, val & 0xFF, plen)


def routes(family="inet"):
    """路由表（netstat -rn，本机实测 6ms；原生 App 建议改用 sysctl NET_RT_DUMP 拿精确 netmask）。"""
    out = _run("netstat", "-rn", "-f", family)
    rows = []
    for line in out.splitlines():
        t = line.split()
        if len(t) < 4 or t[0] in ("Routing", "Internet:", "Internet6:", "Destination"):
            continue
        dest, gw, flags, netif = t[:4]
        if dest == "default":
            dest_c = "default"
        elif family == "inet":
            try:
                dest_c = _norm_cidr4(dest)
            except ValueError:                 # 格式意外时原样保留，别崩
                dest_c = dest
        else:
            if dest.startswith("ff") or dest.startswith("fe80"):  # 多播/链路本地不列
                continue
            dest_c = dest
        rows.append({"目标": dest_c, "网关": gw, "标志": flags, "接口": netif})
    return rows


_FLAG_GLOSS = "U=启用 G=经网关 H=主机路由 S=静态 C=克隆 L=链路层 b=广播 m=多播 W=克隆生成 I=接口域 g=全局"


def render_net(detail, r4, r6=None):
    default_if = next((row["接口"] for row in r4 if row["目标"] == "default"), None)
    print("接口（按累计流量排序；★=承载默认路由）：")
    named = [(n, r) for n, r in detail.items() if r["counters"]]
    named.sort(key=lambda kv: -(kv[1]["counters"]["in"] + kv[1]["counters"]["out"]))
    for name, r in named:
        st = " ".join(
            s for b, s in ((IFF_UP, "UP"), (IFF_RUNNING, "RUNNING"), (IFF_LOOPBACK, "LOOPBACK"),
                           (IFF_POINTOPOINT, "P2P"), (IFF_BROADCAST, "BCAST")) if r["flags"] & b
        )
        addrs = " ".join(r["v4"] + r["v6"][:2]) or "-"
        rate = "   ↓%.1f ↑%.1f KB/s" % (r["rate"][0] / 1024, r["rate"][1] / 1024) if r["rate"] else ""
        cum = "%.1fGB/%.1fGB" % (r["counters"]["in"] / 1000 ** 3, r["counters"]["out"] / 1000 ** 3)
        print("  %s%-8s %-18s mtu%-5s %-38s%s  累计 %s%s"
              % ("★" if name == default_if else " ", name, st, r["mtu"] or "-", addrs, rate, cum,
                 ("  mac " + r["mac"]) if r["mac"] else ""))
    for label, rows in (("IPv4", r4), ("IPv6", r6)):
        if rows is None:
            continue
        print("%s 路由（%d 条，按接口分组）：" % (label, len(rows)))
        grouped = {}
        for row in rows:
            grouped.setdefault(row["接口"], []).append(row)
        for netif, rs in grouped.items():
            items = []
            for row in rs:
                seg = row["目标"]
                if "G" in row["标志"]:
                    seg += " → " + row["网关"]
                if "H" in row["标志"]:
                    seg += "·主机"
                items.append(seg)
            print("  %-6s %s" % (netif, " | ".join(items)))
    print("标志说明：" + _FLAG_GLOSS)


# ── 磁盘 ──────────────────────────────────────────────────────────────
def disk_counters():
    """内部 SSD 的累计读/写字节与操作数（取操作数最多的 IOBlockStorageDriver）。"""
    out = _run("ioreg", "-c", "IOBlockStorageDriver", "-r", "-d", "1", "-w0")
    best = None
    for m in re.finditer(r'"Statistics" = \{([^}]*)\}', out):
        s = m.group(1)

        def num(key):
            mm = re.search(r'"%s"=(\d+)' % re.escape(key), s)
            return int(mm.group(1)) if mm else 0

        ops = num("Operations (Read)") + num("Operations (Write)")
        cand = (ops, num("Bytes (Read)"), num("Bytes (Write)"))
        if best is None or cand[0] > best[0]:
            best = cand
    return {"read": best[1], "write": best[2], "ops": best[0]} if best else {"read": 0, "write": 0, "ops": 0}


def disk_capacity():
    st = os.statvfs("/System/Volumes/Data")
    total = st.f_blocks * st.f_frsize
    avail = st.f_bavail * st.f_frsize
    return {"total": total, "used": total - avail, "avail": avail}


# ── 其它 ──────────────────────────────────────────────────────────────
_mem_total = None


def mem_total():
    global _mem_total
    if _mem_total is None:
        _mem_total = int(_run("sysctl", "-n", "hw.memsize") or 0)
    return _mem_total


def load_and_uptime():
    load = _run("sysctl", "-n", "vm.loadavg").strip().strip("{}").split()
    m = re.search(r"sec = (\d+)", _run("sysctl", "-n", "kern.boottime"))
    up = time.time() - int(m.group(1)) if m else 0
    return {
        "load": [float(x) for x in load],
        "uptime": "%d天%02d:%02d" % (up // 86400, (up % 86400) // 3600, (up % 3600) // 60),
    }


def smart_summary():
    out = _run("smartctl", "-a", "/dev/disk0")
    want = ["Percentage Used", "Available Spare", "Temperature", "Data Units Written", "Power On Hours"]
    got = {}
    for line in out.splitlines():
        for k in want:
            if line.strip().startswith(k):
                got[k] = line.split(":", 1)[1].strip()
    return got


def top_procs(n=5):
    rows = []
    for line in _run("ps", "-Aceo", "pcpu,pmem,comm", "-r").splitlines()[1:]:
        parts = line.split(None, 2)
        if len(parts) == 3:
            rows.append({"cpu%": float(parts[0]), "mem%": float(parts[1]), "进程": parts[2]})
        if len(rows) >= n:
            break
    return rows


# ── 采样与差值 ────────────────────────────────────────────────────────
def counters():
    return {
        "t": time.time(),
        "cpu": cpu_ticks(),
        "pages": memory_pages(),
        "swap": _run("sysctl", "-n", "vm.swapusage").strip(),
        "pressure": int(_run("sysctl", "-n", "kern.memorystatus_vm_pressure_level") or 0),
        "net": net_counters(),
        "disk": disk_counters(),
        "cap": disk_capacity(),
        "up": load_and_uptime(),
    }


def diff(prev, cur):
    dt = max(cur["t"] - prev["t"], 1e-6)
    cpu = [0.0] * len(cur["cpu"])
    for i, (a, b) in enumerate(zip(prev["cpu"], cur["cpu"])):
        d = [b[j] - a[j] for j in range(CPU_STATE_MAX)]
        total = sum(d)
        cpu[i] = 0.0 if total <= 0 else 100.0 * (total - d[2]) / total

    p = cur["pages"]
    swap_m = re.search(r"used = ([\d.]+)M", cur["swap"])

    net = {}
    for name, c in cur["net"].items():
        if name in ("lo0", "gif0", "stf0"):
            continue
        pr = prev["net"].get(name, c)
        din = ((c["in"] - pr["in"]) & U32) / dt
        dout = ((c["out"] - pr["out"]) & U32) / dt
        if (c["in"] or c["out"]) and (din or dout):   # 只显示本秒真有流量的接口
            net[name] = {"下行KB/s": round(din / 1024, 1), "上行KB/s": round(dout / 1024, 1)}
    net = dict(sorted(net.items(), key=lambda kv: -(kv[1]["下行KB/s"] + kv[1]["上行KB/s"]))[:4])

    dc, dp = cur["disk"], prev["disk"]
    mb = 1024.0 * 1024.0
    return {
        "时间": time.strftime("%H:%M:%S"),
        "CPU总%": round(sum(cpu) / len(cpu), 1),
        "CPU各核%": [round(x, 1) for x in cpu],
        "负载(1/5/15)": cur["up"]["load"],
        "运行时长": cur["up"]["uptime"],
        "内存": {
            "总GB": round(mem_total() / 1024 ** 3, 1),
            "已用GB": round((p["active"] + p["wired"] + p["compressor"]) / 1024 ** 3, 2),
            "可用GB": round((p["free"] + p["inactive"]) / 1024 ** 3, 2),
            "压缩GB": round(p["compressor"] / 1024 ** 3, 2),
            "交换已用MB": float(swap_m.group(1)) if swap_m else None,
            "压力": {0: "?", 1: "正常", 2: "警告", 4: "严重"}.get(cur["pressure"], cur["pressure"]),
        },
        "磁盘": {
            "容量GB": round(cur["cap"]["total"] / 1000 ** 3),
            "已用GB": round(cur["cap"]["used"] / 1000 ** 3, 1),
            "可用GB": round(cur["cap"]["avail"] / 1000 ** 3),
            "读MB/s": round(((dc["read"] - dp["read"]) & 0xFFFFFFFFFFFFFFFF) / mb / dt, 2),
            "写MB/s": round(((dc["write"] - dp["write"]) & 0xFFFFFFFFFFFFFFFF) / mb / dt, 2),
            "IOPS": round((dc["ops"] - dp["ops"]) / dt, 0),
        },
        "网络KB/s": net,
    }


def render(s):
    print("──── %s ──── 运行 %s  负载 %s" % (s["时间"], s["运行时长"], "/".join(str(x) for x in s["负载(1/5/15)"])))
    print("CPU   总计 %5.1f%%   各核 %s" % (s["CPU总%"], " ".join("%5.1f" % x for x in s["CPU各核%"])))
    m = s["内存"]
    print("内存  已用 %.2f/%.1f GB  可用 %.2f  压缩 %.2f  交换 %.0f MB  压力 %s"
          % (m["已用GB"], m["总GB"], m["可用GB"], m["压缩GB"], m["交换已用MB"] or 0, m["压力"]))
    d = s["磁盘"]
    print("磁盘  已用 %.1f/%.0f GB  可用 %.0f GB  读 %.2f MB/s  写 %.2f MB/s  %.0f IOPS"
          % (d["已用GB"], d["容量GB"], d["可用GB"], d["读MB/s"], d["写MB/s"], d["IOPS"]))
    if s["网络KB/s"]:
        print("网络  " + "   ".join(
            "%s ↓%.1f ↑%.1f KB/s" % (k, v["下行KB/s"], v["上行KB/s"]) for k, v in s["网络KB/s"].items()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--watch", type=float, metavar="SEC")
    ap.add_argument("--count", type=int, default=0, help="配合 --watch：只刷新 N 次")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--top", action="store_true")
    ap.add_argument("--smart", action="store_true")
    ap.add_argument("--net", action="store_true", help="附接口详情 + IPv4 路由表")
    ap.add_argument("--net-all", action="store_true", help="接口列表包含休眠接口")
    ap.add_argument("--net6", action="store_true", help="路由表附带 IPv6")
    a = ap.parse_args()

    prev = counters()
    n = 0
    while True:
        time.sleep(a.watch if a.watch else 1.0)
        cur = counters()
        s = diff(prev, cur)
        if a.top:
            s["进程TOP"] = top_procs()
        if a.smart:
            s["SSD SMART"] = smart_summary()
        if a.net:
            detail = net_detail(prev["net"], a.net_all)
            r4 = routes("inet")
            r6 = routes("inet6") if a.net6 else None
            if r6 is not None:   # IPv6 的 default 只留和 IPv4 默认路由同一接口的（去掉 9 条 utun 噪音）
                v4def = {row["接口"] for row in r4 if row["目标"] == "default"}
                r6 = [row for row in r6 if row["目标"] != "default" or row["接口"] in v4def]
            s["接口"] = detail
            s["路由IPv4"] = r4
            if r6 is not None:
                s["路由IPv6"] = r6
        if a.json:
            print(json.dumps(s, ensure_ascii=False, indent=1))
        else:
            if a.watch:
                sys.stdout.write("\033[H\033[J")
                sys.stdout.flush()
            render(s)
            if a.top:
                for row in s["进程TOP"]:
                    print("      %6.1f%% CPU %5.1f%% 内存  %s" % (row["cpu%"], row["mem%"], row["进程"]))
            if a.smart:
                print("SMART " + json.dumps(s["SSD SMART"], ensure_ascii=False))
            if a.net:
                render_net(detail, r4, r6)
        prev = cur
        n += 1
        if not a.watch or (a.count and n >= a.count):
            break


if __name__ == "__main__":
    main()
