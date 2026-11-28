import Foundation

public enum AtlasExporter {
    public static func exportJSON(snapshot: AtlasSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    public static func exportBackupArchive(snapshot: AtlasSnapshot, media: [EmbeddedMedia]) throws -> Data {
        let archive = AtlasBackupArchive(snapshot: snapshot, media: media)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    public static func decodeSnapshot(from data: Data) throws -> AtlasSnapshot {
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        if let decoded = try? isoDecoder.decode(AtlasSnapshot.self, from: data) {
            return decoded
        }
        return try JSONDecoder().decode(AtlasSnapshot.self, from: data)
    }

    public static func decodeBackup(from data: Data) throws -> AtlasBackupArchive {
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        if let archive = try? isoDecoder.decode(AtlasBackupArchive.self, from: data) {
            return archive
        }
        if let archive = try? JSONDecoder().decode(AtlasBackupArchive.self, from: data) {
            return archive
        }
        let snapshot = try decodeSnapshot(from: data)
        return AtlasBackupArchive(snapshot: snapshot, media: [])
    }

    public static func exportMarkdown(snapshot: AtlasSnapshot) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        var lines: [String] = []
        lines.append("# myatlas — Personal Field Journal")
        lines.append("")
        lines.append("Exported \(dateFormatter.string(from: snapshot.savedAt)) · \(snapshot.places.count) places · \(snapshot.routes.count) routes")
        lines.append("")

        let entriesByPlace = Dictionary(grouping: snapshot.entries, by: \.placeID)
        let attachmentsByPlace = Dictionary(grouping: snapshot.attachments, by: \.placeID)

        for place in snapshot.places.sorted(by: { $0.visitedAt > $1.visitedAt }) {
            let star = place.isFavorite ? " ★" : ""
            lines.append("## \(place.name)\(star)")
            lines.append("- **Location:** \(place.subtitle) (`\(place.coordinate.formattedString)`)")
            lines.append("- **Category:** \(place.category.displayName)")
            lines.append("- **Visited:** \(dateFormatter.string(from: place.visitedAt))")

            if let rating = place.rating {
                lines.append("- **Rating:** \(rating)/5")
            }

            let placeAttachments = attachmentsByPlace[place.id] ?? []
            let photoCount = placeAttachments.filter { $0.kind == .photo }.count
            let voiceCount = placeAttachments.filter { $0.kind == .voice }.count
            if photoCount > 0 || voiceCount > 0 {
                lines.append("- **Attachments:** \(photoCount) photo(s), \(voiceCount) voice note(s)")
            }

            if let note = place.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                lines.append("")
                lines.append("> \(note)")
            }

            let placeEntries = (entriesByPlace[place.id] ?? []).sorted { $0.createdAt > $1.createdAt }
            if !placeEntries.isEmpty {
                lines.append("")
                lines.append("### Journal Entries")
                for entry in placeEntries {
                    let heading = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = (heading?.isEmpty == false) ? "\(heading!) (\(dateFormatter.string(from: entry.createdAt)))" : dateFormatter.string(from: entry.createdAt)
                    lines.append("- **\(label):** \(entry.body)")
                }
            }
            lines.append("")
        }

        if !snapshot.routes.isEmpty {
            lines.append("## Recorded Routes")
            lines.append("")
            for route in snapshot.routes.sorted(by: { $0.startedAt > $1.startedAt }) {
                let km = String(format: "%.2f km", route.totalDistanceMeters / 1000.0)
                let minutes = Int(route.duration / 60)
                lines.append("- **\(route.title)** — \(dateFormatter.string(from: route.startedAt)) · \(km) · \(minutes) min (\(route.points.count) points)")
                if let note = route.note, !note.isEmpty {
                    lines.append("  \(note)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    public static func exportSinglePlaceMarkdown(
        place: Place,
        entries: [JournalEntry],
        attachments: [PlaceAttachment]
    ) -> String {
        exportMarkdown(
            snapshot: AtlasSnapshot(
                regions: [],
                places: [place],
                entries: entries,
                attachments: attachments,
                routes: []
            )
        )
    }

    public static func exportGPX(routes: [TravelRoute], places: [Place] = []) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<gpx version="1.1" creator="myatlas" xmlns="http://www.topografix.com/GPX/1/1">"#)

        for place in places where place.coordinate.isValid {
            lines.append(#"  <wpt lat="\#(place.latitude)" lon="\#(place.longitude)">"#)
            lines.append("    <time>\(iso.string(from: place.visitedAt))</time>")
            lines.append("    <name>\(xmlEscaped(place.name))</name>")
            if let note = place.note, !note.isEmpty {
                lines.append("    <desc>\(xmlEscaped(note))</desc>")
            }
            lines.append("  </wpt>")
        }

        for route in routes {
            lines.append("  <trk>")
            lines.append("    <name>\(xmlEscaped(route.title))</name>")
            lines.append("    <trkseg>")
            for point in route.points where point.isValid {
                lines.append(#"      <trkpt lat="\#(point.latitude)" lon="\#(point.longitude)">"#)
                if let altitude = point.altitude, altitude.isFinite {
                    lines.append("        <ele>\(altitude)</ele>")
                }
                if let recordedAt = point.recordedAt {
                    lines.append("        <time>\(iso.string(from: recordedAt))</time>")
                }
                lines.append("      </trkpt>")
            }
            lines.append("    </trkseg>")
            lines.append("  </trk>")
        }

        lines.append("</gpx>")
        return lines.joined(separator: "\n")
    }

    public static func sanitizedExportFilename(_ raw: String, fallback: String = "myatlas-export") -> String {
        let allowed = raw.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" }
        let joined = String(allowed).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? fallback : joined
    }

    private static func xmlEscaped(_ string: String) -> String {
        let validXMLScalars = string.unicodeScalars.filter { scalar in
            let v = scalar.value
            return v == 0x09 || v == 0x0A || v == 0x0D || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || (v >= 0x10000 && v <= 0x10FFFF)
        }
        return String(String.UnicodeScalarView(validXMLScalars))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
