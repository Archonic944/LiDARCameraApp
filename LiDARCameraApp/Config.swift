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

