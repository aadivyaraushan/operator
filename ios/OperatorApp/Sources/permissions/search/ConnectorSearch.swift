import Foundation
import OperatorCore

/// The Permissions page's search: which entries a typed query keeps. A name
/// match comes before a match in the description, so "calendar" lists the
/// calendars ahead of an entry that only mentions one. Case and accents are
/// ignored.
enum ConnectorSearch {
    static func matches(in descriptors: [ConnectorDescriptor], query: String) -> [ConnectorDescriptor] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return descriptors }
        let byName = descriptors.filter { Self.contains($0.title, needle) }
        let byDescription = descriptors.filter { descriptor in
            !Self.contains(descriptor.title, needle)
                && [descriptor.readSummary, descriptor.writeSummary]
                    .compactMap { $0 }
                    .contains { Self.contains($0, needle) }
        }
        return byName + byDescription
    }

    private static func contains(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
