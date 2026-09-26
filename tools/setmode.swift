import CoreGraphics
import Foundation

// 用法:
//   setmode list                列出可用模式（含俗称，如 1080p / 720p / 900p）
//   setmode 720p                按俗称切换（推荐，等同于 1280x720）
//   setmode 1280x720            按分辨率切换
// 说明: 用 CGConfigureDisplayWithDisplayMode 改主显示器模式，立即生效、可随时切回。
// 无第三方依赖（不需要 displayplacer）。

// ★ 不能取 args[1]：用 `swift 脚本.swift` 解释执行时，swift 会把自己的
//   `-frontend` 等参数塞进 CommandLine.arguments（实测踩到）。
//   改为跳过以 - 开头的参数（swift 自己的），只看真正的用户参数。
//   并区分「没给参数」与「给了但看不懂」——后者必须报错，不能静默变成 list
//   （否则用户以为切换成功了，其实只是打印了列表）。
let args = CommandLine.arguments
var target = ""
var userArgs: [String] = []
for a in args.dropFirst() {
    if a.hasPrefix("-") { continue }          // swift 注入的 -frontend 等
    userArgs.append(a)
}
if userArgs.isEmpty {
    target = "list"
} else if userArgs.count == 1 {
    let low = userArgs[0].lowercased()
    if low == "list" || low == "ls" || low == "help" || low == "-h" {
        target = "list"
    } else if low.range(of: #"^\d+x\d+$"#, options: .regularExpression) != nil
        || low.range(of: #"^\d+p$"#, options: .regularExpression) != nil {
        target = low
    } else {
        print("看不懂的参数: \(userArgs[0])")
        print("")
        print("用法:")
        print("  setmode list           看所有档位（含 1080p / 720p 俗称与负载占比）")
        print("  setmode 720p           按俗称切换")
        print("  setmode 1280x720       按分辨率切换")
        exit(2)
    }
} else {
    print("参数太多: \(userArgs.joined(separator: " "))（一次只切换一个模式）")
    exit(2)
}

let mainID = CGMainDisplayID()

func currentDesc() -> String {
    guard let m = CGDisplayCopyDisplayMode(mainID) else { return "未知" }
    return "\(m.width)x\(m.height)@\(Int(m.refreshRate))Hz"
}

// 常见分辨率的业界俗称（只收通用叫法；没有通用名的用「—」）
let nameTable: [String: String] = [
    "3840x2160": "4K UHD（2160p）",
    "2560x1600": "WQXGA（1600p）",
    "2560x1440": "2K QHD（1440p）",
    "1920x1080": "1080p 全高清",
    "1600x900":  "900p HD+",
    "1280x720":  "720p 高清",
    "1024x768":  "XGA",
    "800x600":   "SVGA",
    "720x480":   "480p SD",
    "640x480":   "VGA",
]

let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
guard let modes = CGDisplayCopyAllDisplayModes(mainID, opts) as? [CGDisplayMode] else {
    print("无法枚举显示模式")
    exit(1)
}

// 中文字符按 2 列宽计算，否则表格会错位
func dispWidth(_ s: String) -> Int {
    var w = 0
    for u in s.unicodeScalars {
        w += (u.value >= 0x1100 && u.value <= 0xFFFF) ? 2 : 1
    }
    return w
}

func pad(_ s: String, _ n: Int) -> String {
    let cur = dispWidth(s)
    if cur >= n { return s }
    return s + String(repeating: " ", count: n - cur)
}

// ---- 收集所有模式（去重，按像素量降序）----
var seen = Set<String>()
var rows: [(mode: CGDisplayMode, w: Int, h: Int, hz: Int, px: Int)] = []
for m in modes {
    let key = "\(m.width)x\(m.height)@\(Int(m.refreshRate))"
    if seen.contains(key) { continue }
    seen.insert(key)
    rows.append((m, m.width, m.height, Int(m.refreshRate), m.pixelWidth * m.pixelHeight))
}
rows.sort { $0.px > $1.px }

let base = 1920 * 1080

// ---- 列出 ----
if target == "list" || target == "ls" {
    let curMode = CGDisplayCopyDisplayMode(mainID)
    let curKey = curMode.map { "\($0.width)x\($0.height)" } ?? ""
    let curHz = curMode.map { Int($0.refreshRate) } ?? 0
    let curNote = nameTable[curKey].map { "（\($0)）" } ?? ""

    print("当前模式: \(currentDesc())\(curNote)")
    print("")
    print(pad("  模式", 17) + pad("俗称", 24) + pad("刷新率", 10) + pad("像素量", 12) + "≈负载")
    for r in rows {
        let key = "\(r.w)x\(r.h)"
        let alias = nameTable[key] ?? "—"
        var mark = ""
        if key == curKey && r.hz == curHz { mark = "   ← 当前" }
        let load = Double(r.px) / Double(base) * 100.0
        print(pad("  \(r.w)x\(r.h)", 17)
              + pad(alias, 24)
              + pad("\(r.hz)Hz", 10)
              + pad("\(r.px)", 12)
              + String(format: "%5.0f%%", load) + mark)
    }
    print("")
    print("说明：")
    print("  · 「俗称」= 业界通用叫法；`—` 表示该分辨率没有通用俗称（不常见档位）")
    print("  · 「≈负载」= 相对 1080p 的像素量百分比（1080p = 100%）")
    print("  · ⚠️ 这个列只是**显示像素**的相对量。实际 CPU 取决于 UU 会话建立的")
    print("    **码流几何**（UU 把尺寸当参数传给采集接口，与显示模式解耦）：")
    print("    实测把显示切到 1600x900 而码流仍是 1920x1080 时，CPU 与帧率几乎不变，")
    print("    画面反而被拉伸（采集图会被缩放填进码流尺寸）⇒ 帧率低时别只调这里。")
    print("  · 可用俗称直接切换：setmode 720p / setmode 900p / setmode 1080p")
    exit(0)
}

// ---- 解析目标 ----
var tw = 0
var th = 0
var aliasNote = ""

if target.hasSuffix("p"), let h = Int(target.dropLast()) {
    // 俗称写法：按高度匹配；同高度若有多个，取像素最多的（标准宽屏版本）
    let cands = rows.filter { $0.h == h }
    guard let pick = cands.max(by: { $0.px < $1.px }) else {
        print("没有高度为 \(h) 的模式（想找的是 \(target)?）")
        print("用 `setmode list` 看本机支持的档位。")
        exit(3)
    }
    tw = pick.w
    th = pick.h
    aliasNote = "（\(target) → \(pick.w)x\(pick.h)）"
} else {
    let parts = target.split(separator: "x")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else {
        print("非法的模式参数: \(target)（示例: 720p 或 1280x720）")
        exit(2)
    }
    tw = w
    th = h
}

guard let pick = rows.first(where: { $0.w == tw && $0.h == th && $0.hz == 60 })
    ?? rows.first(where: { $0.w == tw && $0.h == th }) else {
    print("不支持的模式: \(tw)x\(th)")
    print("用 `setmode list` 看本机支持的档位。")
    exit(3)
}

// 已是目标尺寸就不动（避免无意义地重配显示器）
if let c = CGDisplayCopyDisplayMode(mainID), pick.w == c.width, pick.h == c.height {
    print("已经是 \(pick.w)x\(pick.h)@\(pick.hz)Hz \(aliasNote)，无需切换")
    exit(0)
}

var config: CGDisplayConfigRef?
let errBegin = CGBeginDisplayConfiguration(&config)
guard errBegin == .success, let cfg = config else {
    print("无法开始显示配置 (err=\(errBegin.rawValue))")
    exit(4)
}

let errSet = CGConfigureDisplayWithDisplayMode(cfg, mainID, pick.mode, nil)
if errSet != .success {
    CGCancelDisplayConfiguration(cfg)
    print("设置模式失败 (err=\(errSet.rawValue))")
    exit(5)
}

let errDone = CGCompleteDisplayConfiguration(cfg, .permanently)
guard errDone == .success else {
    print("提交显示配置失败 (err=\(errDone.rawValue))")
    exit(6)
}

// 回读确认（不能只说「提交成功」）
usleep(800_000)
let after = currentDesc()
let load = Double(pick.px) / Double(base) * 100.0
print("")
print("已提交: \(pick.w)x\(pick.h)@\(pick.hz)Hz \(aliasNote)")
print("回读确认: \(after)")
if after.hasPrefix("\(pick.w)x\(pick.h)") {
    print("★ 切换成功    显示像素 = \(pick.px)（1080p 的 \(String(format: "%.0f", load))%）")
    print("  ⚠️ 注意：这只改「显示模式」。UU 会话的**码流尺寸是 UU 自己定的**，")
    print("     实测显示切小后 CPU 与帧率几乎不变，画面反而被拉伸 ⇒ 别指望用它提帧率。")
    print("  随时切回：setmode 1080p")
} else {
    print("⚠️ 回读与目标不符，请复查")
}
