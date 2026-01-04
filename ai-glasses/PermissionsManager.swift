//
//  PermissionsManager.swift
//  ai-glasses
//
//  Centralized permissions tracking and management
//

import Foundation
import Combine
import CoreBluetooth
import AVFoundation
import Photos
import CoreLocation
import UIKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai-glasses", category: "Permissions")

// MARK: - Permission Status

enum PermissionStatus: String {
    case notDetermined = "Not Requested"
    case authorized = "Allowed"
    case denied = "Denied"
    case restricted = "Restricted"
    case limited = "Limited"
    
    var color: String {
        switch self {
        case .notDetermined: return "orange"
        case .authorized: return "green"
        case .denied: return "red"
        case .restricted: return "gray"
        case .limited: return "yellow"
        }
    }
    
    var systemImage: String {
        switch self {
        case .notDetermined: return "questionmark.circle.fill"
        case .authorized: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .restricted: return "lock.circle.fill"
        case .limited: return "circle.lefthalf.filled"
        }
    }
}

// MARK: - Permission Type

enum PermissionType: String, CaseIterable, Identifiable {
    case location = "Location"
    case microphone = "Microphone"
    case photoLibrary = "Photo Library"
    case bluetooth = "Bluetooth"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .location: return "location.fill"
        case .microphone: return "mic.fill"
        case .photoLibrary: return "photo.fill"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        }
    }
    
    var descriptionWhenAllowed: String {
        switch self {
        case .location:
            return "AI receives your city and country for context-aware responses like weather, local recommendations, and time zone awareness."
        case .microphone:
            return "Voice Agent can hear you through the glasses microphone for natural conversations."
        case .photoLibrary:
            return "Photos and videos captured from glasses are saved to your Photo Library. This is ADD-ONLY access — the app cannot see or read any of your existing photos or videos."
        case .bluetooth:
            return "App can discover and connect to your Meta glasses."
        }
    }
    
    var descriptionWhenDenied: String {
        switch self {
        case .location:
            return "AI will not know your location. Weather, local info, and time zone context will be unavailable."
        case .microphone:
            return "Voice Agent cannot hear you. Voice conversations will not work."
        case .photoLibrary:
            return "Photos and videos will only be saved within the app, not in your Photo Library. You can still capture and view media in the app."
        case .bluetooth:
            return "Cannot connect to glasses. The app will not be able to discover or pair with your glasses."
        }
    }
    
    var isRequired: Bool {
        switch self {
        case .bluetooth, .microphone: return true
        case .location, .photoLibrary: return false
        }
    }
    
    var accessLevel: String? {
        switch self {
        case .location: return "While Using"
        case .photoLibrary: return "Add Only"
        case .microphone, .bluetooth: return nil
        }
    }
    
    var withoutPermissionNote: String? {
        switch self {
        case .location:
            return "Without this permission, AI simply won't know your location automatically."
        case .photoLibrary:
            return "Without this permission, photos and videos captured through glasses via this app won't be saved automatically to your photo feed."
        case .microphone, .bluetooth:
            return nil  // Required permissions - no note needed
        }
    }
}

// MARK: - Permissions Manager

@MainActor
final class PermissionsManager: NSObject, ObservableObject {
    
    static let shared = PermissionsManager()
    
    // Published statuses for each permission
    @Published private(set) var locationStatus: PermissionStatus = .notDetermined
    @Published private(set) var microphoneStatus: PermissionStatus = .notDetermined
    @Published private(set) var photoLibraryStatus: PermissionStatus = .notDetermined
    @Published private(set) var bluetoothStatus: PermissionStatus = .notDetermined
    
    // Bluetooth manager for checking status
    private var centralManager: CBCentralManager?
    private var bluetoothStateCallback: ((CBManagerState) -> Void)?
    
    private override init() {
        super.init()
        refreshAll()
    }
    
    // MARK: - Status Getters
    
    func status(for type: PermissionType) -> PermissionStatus {
        switch type {
        case .location: return locationStatus
        case .microphone: return microphoneStatus
        case .photoLibrary: return photoLibraryStatus
        case .bluetooth: return bluetoothStatus
        }
    }
    
    var missingRequiredPermissionsCount: Int {
        PermissionType.allCases
            .filter { $0.isRequired }
            .filter { status(for: $0) != .authorized }
            .count
    }
    
    // MARK: - Refresh All Statuses
    
    func refreshAll() {
        refreshLocation()
        refreshMicrophone()
        refreshPhotoLibrary()
        refreshBluetooth()
    }
    
    // MARK: - Location
    
    private func refreshLocation() {
        let status = LocationManager.shared.authorizationStatus
        locationStatus = mapCLAuthorizationStatus(status)
        logger.debug("Location status: \(self.locationStatus.rawValue)")
    }
    
    func requestLocation() {
        LocationManager.shared.requestPermissionIfNeeded()
        // Status will update via LocationManager's delegate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshLocation()
        }
    }
    
    private func mapCLAuthorizationStatus(_ status: CLAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        @unknown default: return .notDetermined
        }
    }
    
    // MARK: - Microphone
    
    private func refreshMicrophone() {
        let status = AVAudioApplication.shared.recordPermission
        microphoneStatus = mapAVRecordPermission(status)
        logger.debug("Microphone status: \(self.microphoneStatus.rawValue)")
    }
    
    func requestMicrophone() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.refreshMicrophone()
            }
        }
    }
    
    private func mapAVRecordPermission(_ status: AVAudioApplication.recordPermission) -> PermissionStatus {
        switch status {
        case .undetermined: return .notDetermined
        case .denied: return .denied
        case .granted: return .authorized
        @unknown default: return .notDetermined
        }
    }
    
    // MARK: - Photo Library
    
    private func refreshPhotoLibrary() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        photoLibraryStatus = mapPHAuthorizationStatus(status)
        logger.debug("Photo Library status: \(self.photoLibraryStatus.rawValue)")
    }
    
    func requestPhotoLibrary() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPhotoLibrary()
            }
        }
    }
    
    private func mapPHAuthorizationStatus(_ status: PHAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .notDetermined
        }
    }
    
    // MARK: - Bluetooth
    
    private var bluetoothPermissionCompletion: ((PermissionStatus) -> Void)?
    
    func refreshBluetooth() {
        // Check CBCentralManager authorization without triggering permission dialog
        let authorization = CBCentralManager.authorization
        bluetoothStatus = mapCBManagerAuthorization(authorization)
        logger.debug("Bluetooth status: \(self.bluetoothStatus.rawValue)")
    }
    
    func requestBluetooth() {
        // Creating CBCentralManager triggers the permission dialog if not determined
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
        // Status will update via delegate
    }
    
    /// Request Bluetooth permission with completion callback
    /// - Parameter completion: Called when permission status is determined
    func requestBluetooth(completion: @escaping (PermissionStatus) -> Void) {
        // If already determined, return immediately
        if bluetoothStatus != .notDetermined {
            completion(bluetoothStatus)
            return
        }
        
        // Store completion for delegate callback
        bluetoothPermissionCompletion = completion
        
        // Creating CBCentralManager triggers the permission dialog
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
    }
    
    private func mapCBManagerAuthorization(_ authorization: CBManagerAuthorization) -> PermissionStatus {
        switch authorization {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .allowedAlways: return .authorized
        @unknown default: return .notDetermined
        }
    }
    
    // MARK: - Open App Settings
    
    func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            logger.error("Failed to create settings URL")
            return
        }
        
        UIApplication.shared.open(settingsURL) { success in
            logger.info("Opened app settings: \(success)")
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension PermissionsManager: CBCentralManagerDelegate {
    
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            refreshBluetooth()
            
            // Call completion handler if waiting for permission result
            if let completion = bluetoothPermissionCompletion {
                bluetoothPermissionCompletion = nil
                completion(bluetoothStatus)
            }
        }
    }
}
