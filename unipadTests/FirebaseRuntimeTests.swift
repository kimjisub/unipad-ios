import Foundation
import XCTest
@testable import unipad

@MainActor
final class FirebaseRuntimeTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults, String) -> Void) {
        let suite = "FirebaseRuntimeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suite)
        }
        body(defaults, suite)
    }

    func testLocalOnlySurvivesLaunchWithoutArguments() {
        withDefaults { defaults, suite in
            defaults.setVolatileDomain([FirebaseRuntime.localOnlyLaunchArgument: "YES"], forName: UserDefaults.argumentDomain)
            XCTAssertTrue(FirebaseRuntime.resolveLocalOnly(defaults: defaults, allowsOverride: true))
            XCTAssertEqual(defaults.persistentDomain(forName: suite)?[FirebaseRuntime.localOnlyLaunchArgument] as? Bool, true)
            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            XCTAssertTrue(FirebaseRuntime.resolveLocalOnly(defaults: defaults, allowsOverride: true),
                          "notification launch lost the local-only choice")
        }
    }

    func testExplicitNoClearsPersistedChoice() {
        withDefaults { defaults, suite in
            defaults.set(true, forKey: FirebaseRuntime.localOnlyLaunchArgument)
            defaults.setVolatileDomain([FirebaseRuntime.localOnlyLaunchArgument: "NO"], forName: UserDefaults.argumentDomain)
            XCTAssertFalse(FirebaseRuntime.resolveLocalOnly(defaults: defaults, allowsOverride: true))
            XCTAssertEqual(defaults.persistentDomain(forName: suite)?[FirebaseRuntime.localOnlyLaunchArgument] as? Bool, false)
            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            XCTAssertFalse(FirebaseRuntime.resolveLocalOnly(defaults: defaults, allowsOverride: true))
        }
    }

    func testFreshInstallIsNotLocalOnly() {
        withDefaults { defaults, _ in
            XCTAssertFalse(FirebaseRuntime.resolveLocalOnly(defaults: defaults, allowsOverride: true))
        }
    }

    func testStoreBuildIgnoresArgumentsAndSavedChoice() {
        withDefaults { defaults, _ in
            defaults.set(true, forKey: FirebaseRuntime.localOnlyLaunchArgument)
            defaults.setVolatileDomain([FirebaseRuntime.localOnlyLaunchArgument: "YES"], forName: UserDefaults.argumentDomain)
            XCTAssertFalse(FirebaseRuntime.resolveLocalOnly(defaults: defaults, allowsOverride: false))
            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            XCTAssertFalse(FirebaseRuntime.resolveLocalOnly(defaults: defaults, allowsOverride: false))
        }
    }
}
