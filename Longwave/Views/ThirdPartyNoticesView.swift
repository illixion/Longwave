import SwiftUI

struct ThirdPartyNoticesView: View {
    private let sections: [LicenseSection]

    init() {
        sections = Self.loadSections()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Longwave uses the following open source software:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(sections) { section in
                    licenseSection(name: section.name, copyright: section.copyright, license: section.license)
                }
            }
            .padding()
        }
        .navigationTitle("Third-Party Notices")
    }

    private func licenseSection(name: String, copyright: String, license: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name)
                .font(.title3)
                .fontWeight(.semibold)

            Text(copyright)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(license)
                .font(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
        }
    }

    private static func loadSections() -> [LicenseSection] {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let content = try? String(contentsOf: url) else {
            return []
        }

        let parts = content.components(separatedBy: "<!-- MOONLIGHT_SEPARATOR -->")
        let basePart = parts[0]

        #if MOONLIGHT_ENABLED
        let fullContent = parts.count > 1 ? basePart + parts[1] : basePart
        #else
        let fullContent = basePart
        #endif

        return parseSections(from: fullContent)
    }

    private static func parseSections(from content: String) -> [LicenseSection] {
        // Split on "## " headings (markdown H2)
        let blocks = content.components(separatedBy: "\n## ")
        var sections: [LicenseSection] = []

        for block in blocks.dropFirst() { // skip preamble before first ##
            let lines = block.components(separatedBy: "\n")
            guard let name = lines.first?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { continue }

            let body = lines.dropFirst()
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                // Strip horizontal rules used as section separators in the markdown
                .replacingOccurrences(of: "\n---", with: "")

            // First non-empty line after the heading is the copyright
            let bodyLines = body.components(separatedBy: "\n").filter { !$0.isEmpty }
            let copyright = bodyLines.first ?? ""
            let license = bodyLines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            sections.append(LicenseSection(name: name, copyright: copyright, license: license))
        }

        return sections
    }
}

private struct LicenseSection: Identifiable {
    let id = UUID()
    let name: String
    let copyright: String
    let license: String
}
