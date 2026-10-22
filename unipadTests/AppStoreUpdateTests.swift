import Foundation
import Testing
@testable import unipad

@MainActor
struct AppStoreUpdateTests {
    private let context = AppStoreUpdateContext(version: "4.2.9", bundleID: "kim.jisub.unipad",
                                                 operatingSystem: "17.0", deviceFamily: "iPhone")

    @Test func comparesNumericComponentsWithoutOverflow() {
        for (left, right) in [("4.2.9", "4.2.10"), ("4.2", "4.3"),
                              ("99999999999999999999", "100000000000000000000")] {
            #expect(NumericAppVersion(left)! < NumericAppVersion(right)!)
        }
        #expect(NumericAppVersion("4.3") == NumericAppVersion("4.3.0"))
        #expect(NumericAppVersion("04.003.0") == NumericAppVersion("4.3"))
        for value in ["", "4..3", "4.3.", ".4", "4.3b", " 4.3", "4.-1", "４.３", "4.3+1"] {
            #expect(NumericAppVersion(value) == nil)
        }
    }

    @Test func mapsOnlyKnownStorefrontCountries() {
        #expect(AppStoreCountry.lookupCode("KOR") == "KR")
        #expect(AppStoreCountry.lookupCode("USA") == "US")
        #expect(AppStoreCountry.lookupCode("GBR") == "GB")
        #expect(AppStoreCountry.lookupCode("DEU") == "DE")
        #expect(AppStoreCountry.lookupCode("ZZZ") == nil)
        #expect(AppStoreCountry.lookupCode(nil) == nil)
    }

    @Test func acceptsOnlyANewerCompatibleMatchingApp() throws {
        #expect(try context.hasUpdate(in: payload(), country: "KR") == true)
        #expect(try context.hasUpdate(in: payload(version: "4.2.9"), country: "KR") == false)
        #expect(try context.hasUpdate(in: payload(version: "4.2.8"), country: "KR") == false)
        #expect(try context.hasUpdate(in: payload(version: "4.2.9.0"), country: "KR") == false)
        #expect(throws: (any Error).self) { try context.hasUpdate(in: payload(version: "4.3b"), country: "KR") }
        #expect(throws: (any Error).self) { try context.hasUpdate(in: payload(id: 1), country: "KR") }
        #expect(throws: (any Error).self) { try context.hasUpdate(in: payload(bundle: "another.app"), country: "KR") }
        #expect(try context.hasUpdate(in: payload(minOS: "17.1"), country: "KR") == false)
        #expect(try context.hasUpdate(in: payload(version: "4.2.9", minOS: "17.1"), country: "KR") == false)
        #expect(try context.hasUpdate(in: payload(devices: ["iPadPro-iPadPro"]), country: "KR") == false)
        #expect(throws: (any Error).self) { try context.hasUpdate(in: payload(minOS: "unknown"), country: "KR") }
        #expect(throws: (any Error).self) { try context.hasUpdate(in: payload(devices: []), country: "KR") }
        #expect(throws: (any Error).self) { try context.hasUpdate(in: Data(#"{"resultCount":0,"results":[]}"#.utf8), country: "KR") }
        #expect(throws: (any Error).self) { try context.hasUpdate(in: Data(#"{"resultCount":2,"results":[]}"#.utf8), country: "KR") }
        #expect(throws: (any Error).self) { try context.hasUpdate(in: Data(), country: "KR") }
        #expect(throws: (any Error).self) { try context.hasUpdate(in: Data("broken".utf8), country: "KR") }
        let ahead = AppStoreUpdateContext(version: "4.3", bundleID: context.bundleID,
                                          operatingSystem: "27.0", deviceFamily: "iPhone")
        #expect(try ahead.hasUpdate(in: payload(version: "4.2.10"), country: "KR") == false)
        #expect(try ahead.hasUpdate(in: payload(version: "4.3.0"), country: "KR") == false)
    }

    @Test func rejectsAnAppFromAnotherStoreCountry() {
        #expect(throws: (any Error).self) { try context.hasUpdate(in: payload(storeCountry: "US"), country: "KR") }
    }

    @Test func excludesDevelopmentAndSandboxInstallations() {
        #expect(!AppStoreInstallation.mayCheck(debug: true, version: "4.3", verifiedProduction: true))
        #expect(!AppStoreInstallation.mayCheck(debug: false, version: "4.3b", verifiedProduction: true))
        #expect(!AppStoreInstallation.mayCheck(debug: false, version: "4.3", verifiedProduction: false))
        #expect(AppStoreInstallation.mayCheck(debug: false, version: "4.3", verifiedProduction: true))
    }

    @Test func cachesFor24HoursThenClearsAnExpiredPromptBeforeFailure() async {
        let probe = Probe(data: payload())
        let checker = make(probe)
        await checker.refresh().value
        #expect(checker.updateAvailable)
        probe.now += 86_399
        await checker.refresh().value
        #expect(probe.calls == ["KR"])
        #expect(checker.updateAvailable)
        probe.now += 1
        probe.error = URLError(.notConnectedToInternet)
        await checker.refresh().value
        #expect(!checker.updateAvailable)
        #expect(checker.state == .failed)
        #expect(probe.calls == ["KR", "KR"])
        probe.now += 3_599
        await checker.refresh().value
        #expect(probe.calls.count == 2)
        probe.now += 1
        probe.error = nil
        await checker.refresh().value
        #expect(probe.calls.count == 3)
        #expect(checker.updateAvailable)
    }

    @Test func persistsSuccessAndFailureAcrossCheckerLifetimes() async {
        let probe = Probe(data: payload())
        let initial = make(probe)
        await initial.refresh().value
        #expect(initial.updateAvailable)
        let restored = make(probe)
        await restored.refresh().value
        #expect(restored.updateAvailable)
        #expect(probe.calls.count == 1)
        probe.now += 86_400
        probe.error = URLError(.timedOut)
        await restored.refresh().value
        let failedRestored = make(probe)
        await failedRestored.refresh().value
        #expect(failedRestored.state == .failed)
        #expect(probe.calls.count == 2)
    }

    @Test func keepsAValidPromptWhileRecheckingTheSameStorefront() async {
        let probe = Probe(data: payload())
        let checker = make(probe)
        await checker.refresh().value
        #expect(checker.updateAvailable)
        probe.holdStorefront = true
        probe.holdInstallation = true
        let pending = checker.refresh()
        #expect(checker.updateAvailable)
        await probe.waitUntil { probe.storefrontGate != nil }
        #expect(checker.updateAvailable)
        probe.releaseStorefront()
        await probe.waitUntil { probe.installationGate != nil }
        #expect(checker.updateAvailable)
        probe.releaseInstallation()
        await pending.value
        #expect(checker.updateAvailable)
        #expect(probe.calls == ["KR"])
    }

    @Test func hidesThePromptAsSoonAsTheStorefrontReadsAnotherCountry() async {
        let probe = Probe(data: payload())
        let checker = make(probe)
        await checker.refresh().value
        #expect(checker.updateAvailable)
        probe.country = "USA"
        probe.holdInstallation = true
        let pending = checker.refresh()
        await probe.waitUntil { probe.installationGate != nil }
        #expect(!checker.updateAvailable)
        #expect(checker.state == .unavailable)
        #expect(probe.cache.load() == nil)
        probe.releaseInstallation()
        await pending.value
        #expect(!checker.updateAvailable)
        #expect(probe.calls == ["KR", "US"])
    }

    @Test func hidesThePromptButKeepsTheResultWhileTheStorefrontCannotBeRead() async {
        let probe = Probe(data: payload())
        let checker = make(probe)
        await checker.refresh().value
        #expect(checker.updateAvailable)
        probe.country = nil
        await checker.refresh().value
        #expect(!checker.updateAvailable)
        #expect(checker.state == .unavailable)
        probe.country = "KOR"
        await checker.refresh().value
        #expect(checker.updateAvailable)
        #expect(probe.calls == ["KR"])
    }

    @Test func keepsTheResultWhileTheInstallationCannotBeVerified() async {
        let probe = Probe(data: payload())
        let first = make(probe)
        await first.refresh().value
        #expect(first.updateAvailable)
        probe.production = false
        let unverified = make(probe)
        await unverified.refresh().value
        #expect(!unverified.updateAvailable)
        #expect(probe.cache.load() != nil)
        probe.production = true
        let verified = make(probe)
        await verified.refresh().value
        #expect(verified.updateAvailable)
        #expect(probe.calls == ["KR"])
    }

    @Test func cachesANewerVersionThisDeviceCannotInstallAsNoPromptForADay() async {
        for data in [payload(minOS: "17.1"), payload(devices: ["iPadPro-iPadPro"])] {
            let probe = Probe(data: data)
            let checker = make(probe)
            await checker.refresh().value
            #expect(checker.state == .current)
            #expect(!checker.updateAvailable)
            probe.now += 86_399
            await checker.refresh().value
            let next = make(probe)
            await next.refresh().value
            #expect(next.state == .current)
            #expect(probe.calls == ["KR"])
            probe.now += 1
            await checker.refresh().value
            #expect(probe.calls == ["KR", "KR"])
            #expect(checker.state == .current)
        }
    }

    @Test func neverUsesAnotherCountrysCacheOrAnUnknownCountry() async {
        let probe = Probe(data: payload())
        let checker = make(probe)
        await checker.refresh().value
        probe.country = "USA"
        probe.error = URLError(.notConnectedToInternet)
        await checker.refresh().value
        #expect(!checker.updateAvailable)
        #expect(probe.calls == ["KR", "US"])
        probe.country = nil
        await checker.refresh().value
        #expect(checker.state == .unavailable)
        #expect(!checker.updateAvailable)
        #expect(probe.calls.count == 2)
        probe.country = "ZZZ"
        await checker.refresh().value
        #expect(probe.calls.count == 2)
    }

    @Test func neverChecksExcludedInstallationsOrReusesTheirCache() async {
        let probe = Probe(data: payload())
        let initial = make(probe)
        await initial.refresh().value
        #expect(initial.updateAvailable)
        probe.production = false
        let checker = make(probe)
        await checker.refresh().value
        #expect(!checker.updateAvailable)
        #expect(checker.state == .unavailable)
        #expect(probe.calls.count == 1)
    }

    @Test func coalescesConcurrentRequestsAndDiscardsALateCountryResponse() async throws {
        let probe = Probe(data: payload())
        probe.hold = true
        let checker = make(probe)
        let first = checker.refresh()
        await probe.waitForCall()
        let duplicate = checker.refresh()
        #expect(probe.calls == ["KR"])
        probe.country = "USA"
        checker.storefrontChanged(to: "USA")
        await probe.waitForCall(count: 2)
        probe.release(country: "US", data: Data("broken".utf8))
        await checker.refresh().value
        #expect(!checker.updateAvailable)
        #expect(checker.state == .failed)
        // This transport deliberately ignores cancellation, like a response already queued for delivery.
        probe.release(country: "KR", data: payload())
        await first.value
        await duplicate.value
        #expect(!checker.updateAvailable)
        #expect(checker.state == .failed)
    }

    @Test func cancellationDoesNotPersistAnUpdateOrCallItCurrent() async {
        let probe = Probe(data: payload())
        probe.hold = true
        let checker = make(probe)
        let task = checker.refresh()
        await probe.waitForCall()
        task.cancel()
        probe.release(country: "KR", data: payload())
        await task.value
        #expect(!checker.updateAvailable)
        #expect(checker.state != .current)
        #expect(probe.cache.load() == nil)
    }

    @Test func invalidDataAndOfflineFailuresNeverBecomeCurrent() async {
        for data in [Data(), Data("broken".utf8), payload(id: 0), payload(minOS: "unknown")] {
            let probe = Probe(data: data)
            let checker = make(probe)
            await checker.refresh().value
            #expect(checker.state == .failed)
            #expect(!checker.updateAvailable)
        }
        for code: URLError.Code in [.notConnectedToInternet, .timedOut, .cancelled] {
            let probe = Probe(data: payload())
            probe.error = URLError(code)
            let checker = make(probe)
            await checker.refresh().value
            #expect(!checker.updateAvailable)
            #expect(checker.state != .current)
        }
    }

    private func make(_ probe: Probe) -> AppStoreUpdateChecker {
        AppStoreUpdateChecker(context: context, cache: probe.cache, now: { probe.now },
                              installationAllowed: { await probe.installation() }, storefront: { await probe.storefront() },
                              lookup: { country in try await probe.lookup(country) })
    }

    private func payload(version: String = "4.2.10", id: Int = 6760479102,
                         bundle: String = "kim.jisub.unipad", minOS: String = "17.0",
                         devices: [String] = ["iPhone17Pro-iPhone17Pro", "iPadPro-iPadPro"],
                         storeCountry: String = "KR") -> Data {
        try! JSONSerialization.data(withJSONObject: ["resultCount": 1, "results": [[
            "trackId": id, "bundleId": bundle, "version": version, "minimumOsVersion": minOS,
            "kind": "software", "wrapperType": "software", "supportedDevices": devices,
            "trackViewUrl": "https://apps.apple.com/\(storeCountry.lowercased())/app/unipad/id6760479102",
        ]]])
    }

    @MainActor
    private final class Probe {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var country: String? = "KOR"
        var production = true
        var data: Data
        var error: Error?
        var calls: [String] = []
        var hold = false
        let cache = AppStoreUpdateCache(defaults: UserDefaults(suiteName: "AppStoreUpdateTests-\(UUID())")!)
        var continuations: [String: CheckedContinuation<Data, any Error>] = [:]
        var holdStorefront = false
        var holdInstallation = false
        var storefrontGate: CheckedContinuation<Void, Never>?
        var installationGate: CheckedContinuation<Void, Never>?

        init(data: Data) { self.data = data }
        func storefront() async -> String? {
            if holdStorefront { await withCheckedContinuation { storefrontGate = $0 } }
            return country
        }
        func installation() async -> Bool {
            if holdInstallation { await withCheckedContinuation { installationGate = $0 } }
            return production
        }
        func releaseStorefront() {
            holdStorefront = false
            storefrontGate?.resume()
            storefrontGate = nil
        }
        func releaseInstallation() {
            holdInstallation = false
            installationGate?.resume()
            installationGate = nil
        }
        func lookup(_ country: String) async throws -> Data {
            calls.append(country)
            if hold {
                return try await withCheckedThrowingContinuation { continuations[country] = $0 }
            }
            if let error { throw error }
            return data
        }
        func release(country: String, data: Data) {
            continuations.removeValue(forKey: country)?.resume(returning: data)
        }
        func waitForCall(count: Int = 1) async {
            await waitUntil { self.calls.count >= count }
        }
        func waitUntil(_ condition: () -> Bool) async {
            for _ in 0..<10_000 {
                if condition() { return }
                await Task.yield()
            }
            Issue.record("the awaited step never started")
        }
    }
}
