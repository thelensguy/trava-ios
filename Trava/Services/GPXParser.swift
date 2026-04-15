//  Services/GPXParser.swift
//  Trava
//
//  Parses .gpx files into ExplorationTrack objects.
//  Handles both <trk><trkseg><trkpt> track format and <wpt> waypoint format.
//  Security-scoped resource access is managed automatically for document-picker URLs.

import Foundation
import CoreLocation

// MARK: - Error

enum GPXParseError: LocalizedError {
    case fileNotReadable
    case invalidFormat
    case noCoordinates

    var errorDescription: String? {
        switch self {
        case .fileNotReadable: return "Could not read the GPX file."
        case .invalidFormat:   return "The file is not a valid GPX format."
        case .noCoordinates:   return "No track coordinates found in the file."
        }
    }
}

// MARK: - Parser

struct GPXParser {

    /// Parses a GPX file at `url` into a ready-to-save ExplorationTrack.
    /// Handles security-scoped resource access (UIDocumentPickerViewController URLs).
    /// The `cityName` field is set to the GPX track name; callers should replace it
    /// with a reverse-geocoded city name before saving.
    func parse(url: URL, userId: String) throws -> ExplorationTrack {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            throw GPXParseError.fileNotReadable
        }

        let delegate = GPXDelegate()
        let parser   = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse(), delegate.parseError == nil else {
            throw GPXParseError.invalidFormat
        }
        guard !delegate.points.isEmpty else {
            throw GPXParseError.noCoordinates
        }

        let pts        = delegate.points
        let coords     = pts.map(\.coordinate)
        let trackName  = delegate.trackName.isEmpty
            ? url.deletingPathExtension().lastPathComponent
            : delegate.trackName

        return ExplorationTrack(
            userId:      userId,
            coordinates: coords,
            startedAt:   pts.first?.timestamp ?? Date(),
            endedAt:     pts.last?.timestamp,
            distanceKm:  ExplorationTrack.distance(from: coords),
            cityName:    trackName
        )
    }
}

// MARK: - Internal XMLParserDelegate

private final class GPXDelegate: NSObject, XMLParserDelegate {

    struct Point {
        let coordinate: Coordinate
        let timestamp:  Date?
    }

    var points:     [Point] = []
    var trackName   = ""
    var parseError: Error?

    // Per-element state
    private var chars       = ""
    private var pendingLat: Double?
    private var pendingLon: Double?
    private var pendingTime: Date?
    private var inPoint     = false   // inside <trkpt> or <wpt>
    private var nameSet     = false   // track name already captured

    // ISO 8601 — with and without fractional seconds
    private static let df: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let dfPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attrs: [String: String] = [:]) {
        chars = ""
        switch element {
        case "trkpt", "wpt":
            inPoint    = true
            pendingLat  = attrs["lat"].flatMap(Double.init)
            pendingLon  = attrs["lon"].flatMap(Double.init)
            pendingTime = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        chars += string
    }

    func parser(_ parser: XMLParser,
                didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = chars.trimmingCharacters(in: .whitespacesAndNewlines)
        chars = ""

        switch element {
        case "trkpt", "wpt":
            if let lat = pendingLat, let lon = pendingLon {
                let clCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                points.append(Point(coordinate: Coordinate(clCoord), timestamp: pendingTime))
            }
            inPoint     = false
            pendingLat  = nil
            pendingLon  = nil
            pendingTime = nil

        case "time" where inPoint:
            pendingTime = Self.df.date(from: text) ?? Self.dfPlain.date(from: text)

        case "name" where !inPoint && !nameSet:
            // First <name> outside a point element = track / file name
            trackName = text
            nameSet   = true

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parseError = error
    }
}
