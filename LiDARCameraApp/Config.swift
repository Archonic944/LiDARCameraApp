//
//  Config.swift
//  LiDARCameraApp
//
//  Centralized feature flags and app-mode toggles.
//

import Foundation

enum FeatureFlags {
    // Set to true to force tuning mode without build flags.
    // Prefer using the build flag `-D TUNING_MODE` instead.
    private static let forceTuningOverride = false

    static var tuningMode: Bool {
        #if TUNING_MODE
        return true
        #else
        return forceTuningOverride
        #endif
    }
}

struct DepthLevels {
    static let short: (min: Float, max: Float) = (0.3, 0.35)
    static let medium: (min: Float, max: Float) = (1.4, 1.5)
    static let long: (min: Float, max: Float) = (2.0, 2.1)
    
    static let all: [(min: Float, max: Float)] = [short, medium, long]
}

struct AppConfig {
    static let baseApertureSize: Double = 0.15
}

