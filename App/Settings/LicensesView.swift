import SwiftUI

/// The dependency list shown in Settings. It is a static list rather than a
/// generated file for now; Phase 7 replaces it with the notice text produced
/// alongside the SBOM under `ThirdParty/`, so that what ships and what is
/// listed cannot drift apart.
struct LicensesView: View {
    private struct Dependency: Identifiable {
        let id = UUID()
        let name: String
        let version: String
        let license: String
    }

    private let dependencies = [
        Dependency(name: "FreeRDP", version: "3.31.1", license: "Apache-2.0"),
        Dependency(name: "WinPR", version: "3.31.1", license: "Apache-2.0"),
        Dependency(name: "OpenSSL", version: "4.0.1", license: "Apache-2.0"),
        Dependency(name: "TPCircularBuffer", version: String(localized: "FreeRDP 3.31.1 同梱"), license: "MIT"),
        Dependency(name: "libssh2", version: "1.11.2-dev (3209951)", license: "BSD-3-Clause"),
        Dependency(name: "SwiftTerm", version: "1.20.0", license: "MIT"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(dependencies) { dependency in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dependency.name).font(.headline)
                        Text("\(dependency.version) · \(dependency.license)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("完全な notice と SPDX SBOM はリポジトリの ThirdParty/ にあります。")
            }
        }
        .navigationTitle("ライセンス")
        .keepsNavigationBarOnScroll()
        .navigationBarTitleDisplayMode(.inline)
    }
}
