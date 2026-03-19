//
//  SceneDelegate.swift
//  LiDARCameraApp
//
//  Created by Gabriel C on 10/12/25.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?


    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let _ = (scene as? UIWindowScene) else { return }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        presentOnboardingIfNeeded()
    }

    private var hasCheckedOnboarding = false

    private func presentOnboardingIfNeeded() {
        guard !hasCheckedOnboarding else { return }
        hasCheckedOnboarding = true

        guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }

        // Present onboarding over the root view controller
        DispatchQueue.main.async {
            guard let root = self.window?.rootViewController else { return }
            let onboarding = OnboardingViewController()
            onboarding.modalPresentationStyle = .fullScreen
            root.present(onboarding, animated: true)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
    }

    func sceneWillResignActive(_ scene: UIScene) {
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
    }


}

