import CoreGraphics
import Foundation

// 用法:
//   swift setmode.swift 1280x720    切换到指定模式（可逆）
//   swift setmode.swift list        列出可用模式
// 说明: 用 CGConfigureDisplayWithDisplayMode 改主显示器模式，立即生效、可随时切回。
// 无第三方依赖（不需要 displayplacer）。

// ★ 不能取 args[1]：用 `swift 脚本.swift` 解释执行时，swift 会把自己的
//   `-frontend` 等参数塞进 CommandLine.arguments（实测踩到）。
//   改为扫描全部参数、只认形如「1280x720」的那个。
let args = CommandLine.arguments
var target = "list"
for a in args.dropFirst() where a.range(of: #"^\d+x\d+$"#, options: .regularExpression) != nil {
    target = a
    break
}

let mainID = CGMainDisplayID()

func currentDesc() -> String {
    guard let m = CGDisplayCopyDisplayMode(mainID) else { return "未知" }
    return "\(m.width)x\(m.height)@\(Int(m.refreshRate))Hz"
}

let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
guard let modes = CGDisplayCopyAllDisplayModes(mainID, opts) as? [CGDisplayMode] else {
    print("无法枚举显示模式")
    exit(1)
}

func pad(_ s: String, _ n: Int) -> String {
    if s.count >= n { return s }
    return s + String(repeating: " ", count: n - s.count)
}

// ---- 列出所有模式（去重，按像素量降序）----
var seen = Set<String>()
var rows: [(mode: CGDisplayMode, w: Int, h: Int, hz: Int, px: Int)] = []
for m in modes {
    let key = "\(m.width)x\(m.height)@\(Int(m.refreshRate))"
    if seen.contains(key) { continue }
    seen.insert(key)
    rows.append((m, m.width, m.height, Int(m.refreshRate), m.pixelWidth * m.pixelHeight))
}
rows.sort { $0.px > $1.px }

print("当前模式: \(currentDesc())")
print("")
print(pad("  模式", 16) + pad("刷新率", 9) + pad("像素量", 12) + "1080p 是其 N 倍")
let base = 1920 * 1080
for r in rows {
    let label = "  " + pad("\(r.w)x\(r.h)", 14)
    let ratio = Double(base) / Double(r.px)
    let ratioStr = String(format: "%.2fx", ratio)
    print(label + pad("\(r.hz)Hz", 9) + pad("\(r.px)", 12) + ratioStr)
}

if target == "list" {
    exit(0)
}

// ---- 解析目标 ----
let parts = target.lowercased().split(separator: "x")
guard parts.count == 2, let tw = Int(parts[0]), let th = Int(parts[1]) else {
    print("非法的模式参数: \(target)（示例: 1280x720）")
    exit(2)
}

guard let pick = rows.first(where: { $0.w == tw && $0.h == th && $0.hz == 60 })
    ?? rows.first(where: { $0.w == tw && $0.h == th }) else {
    print("不支持的模式: \(target)")
    exit(3)
}

if pick.w == CGDisplayCopyDisplayMode(mainID)?.width,
   pick.h == CGDisplayCopyDisplayMode(mainID)?.height {
    print("已经是 \(target)，无需切换")
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
print("")
print("已提交: \(target)")
print("回读确认: \(after)")
if after.hasPrefix("\(tw)x\(th)") {
    print("★ 切换成功")
} else {
    print("⚠️ 回读与目标不符，请复查")
}
