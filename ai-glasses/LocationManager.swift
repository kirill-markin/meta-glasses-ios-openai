//
//  LocationManager.swift
//  ai-glasses
//
//  Manages location permissions and geocoding for context-aware AI
//

import Foundation
import Combine
import CoreLocation
import MapKit
import os.log

@MainActor
final class LocationManager: NSObject, ObservableObject {
    
    static let shared = LocationManager()
    
    @Published private(set) var locationString: String?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai-glasses", category: "Location")
    private var lastGeocodedLocation: CLLocation?
    
    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorizationStatus = locationManager.authorizationStatus
    }
    
    /// Request location permission if not determined
    func requestPermissionIfNeeded() {
        if authorizationStatus == .notDetermined {
            logger.info("Requesting location permission")
            locationManager.requestWhenInUseAuthorization()
        } else if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            requestLocation()
        }
    }
    
    /// Request current location and geocode it
    func requestLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            logger.debug("Location not authorized, skipping request")
            return
        }
        
        locationManager.requestLocation()
    }
    
    /// Reverse geocode location to city and country using MapKit
    private func geocodeLocation(_ location: CLLocation) {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            logger.warning("Failed to create reverse geocoding request")
            return
        }
        
        Task {
            do {
                let mapItems = try await request.mapItems
                
                guard let mapItem = mapItems.first,
                      let address = mapItem.address else {
                    logger.warning("No map item or address found")
                    return
                }
                
                // Use shortAddress for concise location (typically "City, Country")
                if let shortAddr = address.shortAddress, !shortAddr.isEmpty {
                    locationString = shortAddr
                    logger.info("Location resolved: \(self.locationString ?? "nil")")
                }
            } catch {
                logger.error("Geocoding failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        Task { @MainActor in
            // Skip if location hasn't changed significantly (within 100m)
            if let lastLocation = lastGeocodedLocation,
               location.distance(from: lastLocation) < 100 {
                return
            }
            
            logger.debug("Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            lastGeocodedLocation = location
            geocodeLocation(location)
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            logger.error("Location error: \(error.localizedDescription)")
        }
    }
    
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            logger.info("Location authorization changed: \(String(describing: self.authorizationStatus.rawValue))")
            // Location is requested on-demand when starting a discussion, not at app launch
        }
    }
}
