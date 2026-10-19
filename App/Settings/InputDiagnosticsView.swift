import SwiftUI
import InputCore

/// Counters from the focused session's keyboard arbiter, and the opt-in
/// trace of non-character keys. Nothing here can show what was typed.
struct InputDiagnosticsView: View {
    @Environment(AppEnvironment.self) private var environment

    private var center: InputDiagnosticsCenter { environment.inputDiagnostics }

    var body: some View {
        Form {
            Section {
                Toggle("非文字キーを記録", isOn: Binding(
                    get: { center.isTraceRequested },
                    set: { center.setTraceRequested($0) }
                ))
                .accessibilityIdentifier("input-trace-toggle")
                if let end = center.traceEndsAt {
                    Text("\(end.formatted(date: .omitted, time: .shortened)) に自動で停止します")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("英数/かな、変換/無変換、修飾キーなど文字を生まないキーだけを、メモリ上に最大 \(InputDiagnostics.traceCapacity) 件記録します。保存も送信もしません。")
            }

            Section("結果") {
                ForEach(InputOutcome.allCases, id: \.self) { outcome in
                    LabeledContent(Self.label(outcome), value: "\(center.latest.count(outcome))")
                }
            }

            Section("一括解放") {
                ForEach(InputReleaseReason.allCases, id: \.self) { reason in
                    LabeledContent(Self.label(reason), value: "\(center.latest.count(reason))")
                }
            }

            if !center.latest.trace.isEmpty {
                Section("記録") {
                    ForEach(center.latest.trace.reversed(), id: \.sequence) { entry in
                        HStack {
                            Text(Self.keyName(entry.usage)).font(.body.monospaced())
                            Text(entry.transition == .down ? "↓" : "↑")
                            Spacer()
                            Text(entry.source == .uiKit ? "UIKit" : "GC")
                                .foregroundStyle(.secondary)
                            Text(Self.label(entry.outcome))
                                .foregroundStyle(entry.outcome == .forwarded ? .primary : Color.orange)
                        }
                        .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("入力診断")
        .keepsNavigationBarOnScroll()
        .accessibilityIdentifier("input-diagnostics-screen")
    }

    static func label(_ outcome: InputOutcome) -> String {
        switch outcome {
        case .forwarded: return String(localized: "送信")
        case .duplicate: return String(localized: "重複 down")
        case .orphan: return String(localized: "対応のない up")
        case .otherSource: return String(localized: "別経路（未採用）")
        case .quarantined: return String(localized: "解放後の押下")
        case .gated: return String(localized: "入力停止中")
        }
    }

    static func label(_ reason: InputReleaseReason) -> String {
        switch reason {
        case .gateClosed: return String(localized: "入力停止")
        case .focusLost: return String(localized: "フォーカス喪失")
        case .pressesCancelled: return String(localized: "押下キャンセル")
        case .keyboardDisconnected: return String(localized: "キーボード切断")
        case .sourcePolicyChanged: return String(localized: "経路設定の変更")
        case .surfaceRemoved: return String(localized: "画面終了")
        }
    }

    static func keyName(_ usage: UInt16) -> String {
        switch usage {
        case 0x90: return String(localized: "かな")
        case 0x91: return String(localized: "英数")
        case 0x87: return String(localized: "ろ")
        case 0x88: return String(localized: "カタカナ")
        case 0x89: return "¥"
        case 0x8A: return String(localized: "変換")
        case 0x8B: return String(localized: "無変換")
        case 0x94: return String(localized: "半/全")
        case 0x39: return "CapsLock"
        case 0xE0: return "L-Ctrl"
        case 0xE1: return "L-Shift"
        case 0xE2: return "L-Opt"
        case 0xE3: return "L-Cmd"
        case 0xE4: return "R-Ctrl"
        case 0xE5: return "R-Shift"
        case 0xE6: return "R-Opt"
        case 0xE7: return "R-Cmd"
        default: return String(format: "0x%02X", usage)
        }
    }
}
