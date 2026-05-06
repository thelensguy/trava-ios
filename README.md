![Platform](https://img.shields.io/badge/Platform-iOS%2017+-007AFF?style=flat-square)
![Language](https://img.shields.io/badge/Language-Swift-FA7343?style=flat-square)
![Status](https://img.shields.io/badge/Status-In%20Development-green?style=flat-square)

# Trava

**Trava is an iOS app that passively tracks your exploration and visualizes your movement patterns as beautiful city maps.** Remember every city you've explored with boundary silhouettes drawn from real map data, detailed stats, and shareable cards — all without ever pressing record.

> Personal portfolio project. Built with Swift and [Claude Code](https://claude.ai/code).

---

## Features

- **Passive GPS tracking** — runs silently in the background, no buttons required
- **Heatmap visualization** — glowing paths show where you go most, built with a custom CoreGraphics renderer
- **City auto-detection** — identifies which city you're in from your GPS coordinates and fetches its real boundary from OpenStreetMap
- **City boundary silhouettes** — crisp outlines of every city you've explored, rendered as shareable cards
- **Coverage tracking** — grid-cell algorithm calculates what percentage of a city you've actually walked
- **Import from anywhere** — bring in routes from Apple Health, Garmin, Strava, or any GPX file
- **Granular tracking controls** — choose GPS precision (Battery Saver / Balanced / Precise), toggle background mode, pause anytime
- **Offline-first** — all data lives on device in CoreData; Firebase syncs when you're signed in
- **Guest mode** — full functionality with no account required

---

## Screenshots

<table>
  <tr>
    <td align="center" width="33%">
      <img src="screenshots/map-heatmap.png" width="220" alt="Map with heatmap"/>
      <br/>
      <sub><b>Map & Heatmap</b><br/>Glowing paths show exploration density. The active region card shows total distance and track count. Green dot confirms passive tracking is live.</sub>
    </td>
    <td align="center" width="33%">
      <img src="screenshots/map-satellite.png" width="220" alt="Satellite map with record pill"/>
      <br/>
      <sub><b>Satellite View</b><br/>Switch between Standard, Satellite, and Hybrid map styles. Tap <b>Record</b> to start a focused high-precision session on top of passive tracking.</sub>
    </td>
    <td align="center" width="33%">
      <img src="screenshots/cities-list.png" width="220" alt="Cities dashboard"/>
      <br/>
      <sub><b>Cities Dashboard</b><br/>Browse all explored cities with OSM boundary thumbnails. 20 cities, 614 mi, 474 tracks — all auto-detected without manual tagging.</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="33%">
      <img src="screenshots/city-detail.png" width="220" alt="City detail — Los Altos"/>
      <br/>
      <sub><b>City Detail</b><br/>Deep dive into a city with its boundary silhouette, distance, sessions, and coverage percentage. Share a snapshot directly to social media.</sub>
    </td>
    <td align="center" width="33%">
      <img src="screenshots/settings-tracking.png" width="220" alt="Tracking settings"/>
      <br/>
      <sub><b>Tracking Settings</b><br/>Fine-tune GPS precision, toggle background tracking, pause all location updates, and switch between km and miles.</sub>
    </td>
    <td align="center" width="33%">
      <img src="screenshots/import-tracks.png" width="220" alt="Import tracks"/>
      <br/>
      <sub><b>Import Tracks</b><br/>Pull in workouts from Apple Health by date range, or import .gpx files from Garmin, Strava, AllTrails, and more.</sub>
    </td>
  </tr>
</table>

---

## Tech Stack

| Technology | Role |
|---|---|
| **Swift / SwiftUI** | Primary language and UI framework |
| **CoreData** | Offline-first local persistence for tracks and cities |
| **CoreLocation** | Passive background tracking + active recording sessions |
| **MapKit** | Interactive map, polyline overlays, reverse geocoding |
| **Firebase Auth** | Google Sign-In and anonymous guest sessions |
| **Firebase Firestore** | Cloud backup and cross-device sync |
| **HealthKit** | Import workout routes from Apple Health |
| **OpenStreetMap / Nominatim** | City boundary polygon data for silhouette cards |

---

## Architecture Highlights

- **Offline-first data layer** — CoreData is the source of truth; Firestore syncs in the background when the user is signed in
- **Always-on passive tracking + focused sessions** — passive mode uses coarse GPS (10m accuracy, 20m filter) to preserve battery; tapping Record switches to best-accuracy mode, then restores passive on stop
- **Custom heatmap renderer** — CoreGraphics draws heat tiles directly onto a `MKOverlayRenderer`, blending pass counts into a color gradient without a third-party library
- **Multi-city track splitting** — a single GPS track spanning multiple cities is split by sampling coordinates against boundary polygons and attributed to each city independently
- **Grid-cell coverage algorithm** — divides a city's bounding box into ~50m cells, marks cells that contain a recorded GPS point as visited, then computes the ratio against the city polygon area
- **Negative cache for boundary lookups** — failed Nominatim responses are cached for 7 days to avoid hammering the API on repeated lookups for unsupported place names
- **Speed-based teleport filter** — points implying movement faster than 150 km/h are rejected and trigger a passive track segment close, eliminating GPS jumps from poor signal

---

## Roadmap

- Neighborhood-level exploration tracking
- Social features — friends, shared maps, leaderboards
- Challenges and exploration goals
- Web dashboard
- Pro tier via StoreKit

---

## Status

In active development. Personal portfolio project — not open source.

*Built with [Claude Code](https://claude.ai/code) + [Google Stitch](https://stitch.withgoogle.com)*
