//  Services/LocationManager.swift
//  Trava
//
//  Always-on passive tracking + optional explicit recording sessions.
//
//  Passive mode (auto, background):
//    • Starts automatically once "Always Allow" permission is granted
//    • kCLLocationAccuracyNearestTenMeters, 20 m distance filter
//    • allowsBackgroundLocationUpdates = true, pausesLocationUpdatesAutomatically = true
//    • Groups points into tracks by a 10-minute inactivity gap
//    • Emits a closed track via pendingPassiveTrack for TravaApp to save
//
//  Explicit recording mode (user-initiated):
//    • kCLLocationAccuracyBest, 8 m filter, pausesAutomatically = false
//    • Points routed to currentSessionPoints; passive accumulation paused
//    • On stop, passive mode resumes at its coarser settings
//
//  Reverse geocode (fix 3):
//    • Debounced to max once per 30 seconds
//    • Result cached in UserDefaults so it survives relaunches

import Foundation
import CoreLocation
import MapKit
import Combine

// MARK: - Tracking Precision

enum TrackingPrecision: String, CaseIterable {
    case batterySaver  = "batterySaver"
    case balanced      = "balanced"
    case highPrecision = "highPrecision"

    var title: String {
        switch self {
        case .batterySaver:  return "Battery Saver"
        case .balanced:      return "Balanced"
        case .highPrecision: return "High Precision"
        }
    }

    /// Short label for segmented picker
    var shortTitle: String {
        switch self {
        case .batterySaver:  return "Saver"
        case .balanced:      return "Balanced"
        case .highPrecision: return "Precise"
        }
    }

    var subtitle: String {
        switch self {
        case .batterySaver:  return "100m accuracy, 50m filter — minimal battery use"
        case .balanced:      return "10m accuracy, 20m filter — default"
        case .highPrecision: return "Best GPS accuracy, 5m filter — higher battery use"
        }
    }

    var accuracy: CLLocationAccuracy {
        switch self {
        case .batterySaver:  return kCLLocationAccuracyHundredMeters
        case .balanced:      return kCLLocationAccuracyNearestTenMeters
        case .highPrecision: return kCLLocationAccuracyBest
        }
    }

    var distanceFilter: CLLocationDistance {
        switch self {
        case .batterySaver:  return 50
        case .balanced:      return 20
        case .highPrecision: return 5
        }
    }
}

@MainActor
final class LocationManager: NSObject, ObservableObject {

    // MARK: - Published

    /// Latest GPS fix.
    @Published var currentLocation: CLLocation?

    /// CLLocationManager authorization status.
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// True while an explicit recording session is active.
    @Published var isRecording = false

    /// True when passive tracking has been manually paused by the user.
    @Published var isPassiveTrackingPaused = false

    /// Live path coordinates — grows on every accepted GPS point (passive + active).
    /// Reset to [] when the current segment ends.  Used for real-time map drawing.
    @Published var currentSessionPoints: [CLLocationCoordinate2D] = []

    /// A completed passive track, ready for the caller to persist.
    /// Reset to nil after saving by the observer (TravaApp).
    @Published var pendingPassiveTrack: [CLLocation]? = nil

    /// Reverse-geocoded name of the current location.
    /// Pre-seeded from cache so it survives relaunches.
    @Published var currentPlaceName: String

    // MARK: - Private state

    private let manager = CLLocationManager()

    // Passive tracking
    private var isPassiveTracking = false
    private var passiveSessionPoints: [CLLocation] = []
    private var lastPassivePointTime: Date?
    private var passiveGapWorkItem: DispatchWorkItem?  // fires after 10-min inactivity

    // Foreground recording accumulator (CLLocation for distance calculation)
    private var recordedLocations: [CLLocation] = []

    // Reverse geocode throttle
    private var lastGeocodeTime: Date?
    private static let placeNameKey = "trava.lastPlaceName"

    // Speed filter
    private var lastAcceptedLocation: CLLocation?
    private static let maxSpeedMS: Double = 150.0 / 3.6   // 150 km/h in m/s

    // MARK: - Init

    override init() {
        currentPlaceName = UserDefaults.standard.string(forKey: Self.placeNameKey) ?? "Locating..."
        super.init()
        manager.delegate        = self
        manager.activityType    = .fitness
        authorizationStatus     = manager.authorizationStatus

        // Auto-start passive if permission already granted (e.g. app relaunch).
        if manager.authorizationStatus == .authorizedAlways {
            applyPassiveSettings()
            isPassiveTracking = true
            manager.startUpdatingLocation()
        }

        // Clear recording state when the CoreData store is reset.
        NotificationCenter.default.addObserver(
            forName: PersistenceController.didResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Stop any active recording session.
                if self.isRecording {
                    _ = self.stopForegroundTracking()
                }
                self.currentSessionPoints  = []
                self.recordedLocations     = []
                self.pendingPassiveTrack   = nil
                self.passiveSessionPoints  = []
                self.passiveGapWorkItem?.cancel()
                self.passiveGapWorkItem    = nil
                self.lastPassivePointTime  = nil
                self.lastAcceptedLocation  = nil
            }
        }
    }

    // MARK: - Permissions

    func requestPermissions() {
        switch manager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    // MARK: - Passive tracking

    private func applyPassiveSettings() {
        manager.desiredAccuracy                = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter                 = 20
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
    }

    // MARK: - Explicit (foreground) recording

    func startForegroundTracking() {
        // Close any open passive track before switching modes.
        closePassiveTrack()

        recordedLocations    = []
        currentSessionPoints = []
        isRecording = true

        manager.desiredAccuracy                = kCLLocationAccuracyBest
        manager.distanceFilter                 = 8
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
    }

    @discardableResult
    func stopForegroundTracking() -> [CLLocation] {
        let recorded     = recordedLocations
        recordedLocations    = []
        currentSessionPoints = []
        isRecording = false

        // Restore passive settings.
        if isPassiveTracking {
            applyPassiveSettings()
        } else {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
        }

        return recorded
    }

    // MARK: - Passive track management

    private func handlePassivePoint(_ location: CLLocation) {
        let now = Date()

        // If there's been a gap > 10 minutes, close the old track.
        if let last = lastPassivePointTime, now.timeIntervalSince(last) > 600 {
            closePassiveTrack()
        }

        lastPassivePointTime = now
        passiveSessionPoints.append(location)

        // Reset the inactivity timer.
        passiveGapWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.closePassiveTrack()
        }
        passiveGapWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: item)
    }

    private func closePassiveTrack() {
        passiveGapWorkItem?.cancel()
        passiveGapWorkItem = nil

        // Need at least 2 points to form a valid track.
        guard passiveSessionPoints.count >= 2 else {
            passiveSessionPoints = []
            lastPassivePointTime = nil
            currentSessionPoints = []
            return
        }

        // Calculate distance before committing — filter GPS noise / ghost tracks.
        var totalMeters = 0.0
        for i in 1..<passiveSessionPoints.count {
            totalMeters += passiveSessionPoints[i].distance(from: passiveSessionPoints[i - 1])
        }
        guard totalMeters / 1000.0 > 0.01 else {
            passiveSessionPoints = []
            lastPassivePointTime = nil
            currentSessionPoints = []
            return
        }

        pendingPassiveTrack  = passiveSessionPoints
        passiveSessionPoints = []
        lastPassivePointTime = nil
        currentSessionPoints = []   // clear live path when segment closes
    }

    // MARK: - Settings API (called from SettingsView)

    /// Applies a TrackingPrecision to the passive (background) manager.
    /// No-op during an active recording session.
    func applyPrecision(_ precision: TrackingPrecision) {
        guard !isRecording else { return }
        manager.desiredAccuracy = precision.accuracy
        manager.distanceFilter  = precision.distanceFilter
    }

    /// Enables or disables background location updates.
    func setBackgroundTracking(_ enabled: Bool) {
        manager.allowsBackgroundLocationUpdates = enabled
    }

    /// Pauses passive tracking (user toggle in settings).
    func pausePassiveTracking() {
        guard !isPassiveTrackingPaused else { return }
        isPassiveTrackingPaused = true
        if !isRecording { manager.stopUpdatingLocation() }
    }

    /// Resumes passive tracking after a user-initiated pause.
    func resumePassiveTracking() {
        guard isPassiveTrackingPaused else { return }
        isPassiveTrackingPaused = false
        if !isRecording {
            applyPassiveSettings()
            manager.startUpdatingLocation()
        }
    }

    // MARK: - Reverse geocode (debounced, 30 s)

    private func reverseGeocodeIfNeeded() {
        let now = Date()
        if let last = lastGeocodeTime, now.timeIntervalSince(last) < 30 { return }
        lastGeocodeTime = now
        guard let location = currentLocation else { return }

        Task { [weak self] in
            guard let self else { return }
            let item = await Self.reverseGeocode(coordinate: location.coordinate)
            let name = item?.addressRepresentations?.cityWithContext
                ?? item?.addressRepresentations?.cityName
                ?? "Unknown"
            self.currentPlaceName = name
            UserDefaults.standard.set(name, forKey: Self.placeNameKey)
        }
    }

    private static func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> MKMapItem? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        return try? await request.mapItems.first
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedAlways, !isPassiveTracking {
                isPassiveTracking = true
                applyPassiveSettings()
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        // Filter stale / inaccurate fixes.
        let fresh = locations.filter {
            $0.horizontalAccuracy > 0 &&
            $0.horizontalAccuracy <= 100 &&
            $0.timestamp.timeIntervalSinceNow > -10
        }
        guard !fresh.isEmpty else { return }

        Task { @MainActor in
            var accepted: [CLLocation] = []
            for point in fresh {
                // Speed check: compare against last accepted point.
                if let prev = lastAcceptedLocation {
                    let dist  = point.distance(from: prev)
                    let dt    = point.timestamp.timeIntervalSince(prev.timestamp)
                    if dt > 0 {
                        let speedMS = dist / dt
                        if speedMS > Self.maxSpeedMS {
                            let speedKmH = speedMS * 3.6
                            print("[LocationManager] Teleport detected: \(String(format: "%.0f", speedKmH)) km/h — starting fresh segment")
                            lastAcceptedLocation = nil
                            closePassiveTrack()
                            continue
                        }
                    }
                }
                lastAcceptedLocation = point
                accepted.append(point)
            }

            guard let latest = accepted.last ?? fresh.last else { return }
            currentLocation = latest
            reverseGeocodeIfNeeded()

            // Append live-path coordinates for both modes.
            let newCoords = accepted.map { $0.coordinate }
            currentSessionPoints.append(contentsOf: newCoords)

            if isRecording {
                recordedLocations.append(contentsOf: accepted)
            } else if isPassiveTracking {
                for point in accepted { handlePassivePoint(point) }
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        print("[LocationManager] \(error.localizedDescription)")
    }
}
