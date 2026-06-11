import LocalAIKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import SwiftUI

#if canImport(UIKit)
final class LocalAIKitDemoAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            LocalAIKitDownloadManager.shared.handleBackgroundEvents(
                identifier: identifier,
                completionHandler: completionHandler
            )
        }
    }
}
#elseif canImport(AppKit)
final class LocalAIKitDemoAppDelegate: NSObject, NSApplicationDelegate {
    func application(
        _ application: NSApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            LocalAIKitDownloadManager.shared.handleBackgroundEvents(
                identifier: identifier,
                completionHandler: completionHandler
            )
        }
    }
}
#endif

@main
struct LocalAIKitDemoApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(LocalAIKitDemoAppDelegate.self) private var appDelegate
    #elseif canImport(AppKit)
    @NSApplicationDelegateAdaptor(LocalAIKitDemoAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
