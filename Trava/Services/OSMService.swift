//  Services/OSMService.swift
//  Trava
//
//  Fetches city boundary polygons from OpenStreetMap Nominatim API.
//  Results are cached in CoreData (CityBoundaryEntity) for 30 days.
//
//  Nominatim usage policy:
//    • User-Agent header identifying the app is required.
//    • Max 1 request per second — enforced via rate-limit sleep.
//    • https://operations.osmfoundation.org/policies/nominatim/

import Foundation
import CoreData

actor OSMService {

    /// Shared singleton.  @MainActor so PersistenceController.shared (also @MainActor)
    /// can be safely captured at initialisation time.
    @MainActor static let shared = OSMService(persistence: PersistenceController.shared)

    private let persistence: PersistenceController
    private var lastRequestTime: Date?

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    private static let cacheDuration: TimeInterval = 30 * 24 * 3_600   // 30 days
    private static let userAgent = "Trava/1.0 (iOS exploration-tracking app)"

    // MARK: - Public API

    /// Returns the outer boundary ring for a city as [lon, lat] pairs.
    /// Fetches from Nominatim on cache miss; returns nil if no polygon is available.
    func fetchCityBoundary(cityName: String, country: String) async -> [[Double]]? {
        if let cached = await loadFromCache(cityName: cityName, country: country) {
            return cached
        }

        // Enforce max 1 req/s per Nominatim policy.
        if let last = lastRequestTime {
            let wait = 1.0 - Date().timeIntervalSince(last)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequestTime = Date()

        guard let coords = await fetchFromNominatim(cityName: cityName, country: country) else {
            return nil
        }

        await saveToCache(cityName: cityName, country: country, coords: coords)
        return coords
    }

    // MARK: - Nominatim

    private func fetchFromNominatim(cityName: String, country: String) async -> [[Double]]? {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        components.queryItems = [
            URLQueryItem(name: "city",             value: cityName),
            URLQueryItem(name: "country",          value: country),
            URLQueryItem(name: "polygon_geojson",  value: "1"),
            URLQueryItem(name: "format",           value: "geojson"),
            URLQueryItem(name: "limit",            value: "1"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return parseGeoJSON(data)
    }

    private func parseGeoJSON(_ data: Data) -> [[Double]]? {
        guard
            let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let features = json["features"] as? [[String: Any]],
            let first    = features.first,
            let geometry = first["geometry"] as? [String: Any],
            let type     = geometry["type"] as? String
        else { return nil }

        switch type {
        case "Polygon":
            // [[[lon, lat]]] — first element is the outer ring.
            let rings = geometry["coordinates"] as? [[[Double]]]
            return rings?.first

        case "MultiPolygon":
            // [[[[lon, lat]]]] — take largest polygon's outer ring.
            guard let polys = geometry["coordinates"] as? [[[[Double]]]] else { return nil }
            // Pick the polygon with the most points (usually the main body).
            return polys.max(by: { ($0.first?.count ?? 0) < ($1.first?.count ?? 0) })?.first

        default:
            return nil
        }
    }

    // MARK: - Cache read

    private func loadFromCache(cityName: String, country: String) async -> [[Double]]? {
        let context = persistence.container.newBackgroundContext()
        return await context.perform {
            let req = NSFetchRequest<CityBoundaryEntity>(entityName: "CityBoundaryEntity")
            req.predicate  = NSPredicate(
                format: "cityName ==[c] %@ AND country ==[c] %@", cityName, country
            )
            req.fetchLimit = 1
            guard let entity = try? context.fetch(req).first else { return nil }

            // Expire stale entries.
            let age = Date().timeIntervalSince(entity.fetchedAt)
            if age > OSMService.cacheDuration {
                context.delete(entity)
                try? context.save()
                return nil
            }

            return try? JSONDecoder().decode([[Double]].self, from: entity.coordinatesData)
        }
    }

    // MARK: - Cache write

    private func saveToCache(cityName: String, country: String, coords: [[Double]]) async {
        let context = persistence.container.newBackgroundContext()
        await context.perform {
            // Remove any stale entries first.
            let req = NSFetchRequest<CityBoundaryEntity>(entityName: "CityBoundaryEntity")
            req.predicate = NSPredicate(
                format: "cityName ==[c] %@ AND country ==[c] %@", cityName, country
            )
            (try? context.fetch(req))?.forEach { context.delete($0) }

            let entity               = CityBoundaryEntity(context: context)
            entity.cityName          = cityName
            entity.country           = country
            entity.coordinatesData   = (try? JSONEncoder().encode(coords)) ?? Data()
            entity.fetchedAt         = Date()
            try? context.save()
        }
    }
}
