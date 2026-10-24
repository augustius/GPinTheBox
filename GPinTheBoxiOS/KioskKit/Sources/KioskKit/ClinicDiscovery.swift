import Foundation
import Network
import Observation
import KioskProtocol

public enum ClinicChoice: Equatable, Sendable { case none, connected(String), needsPicker([String]) }

public enum ClinicSelection {
    public static func choose(available: [String], remembered: String?) -> ClinicChoice {
        if let remembered, available.contains(remembered) { return .connected(remembered) }
        switch available.count {
        case 0: return .none
        case 1: return .connected(available[0])
        default: return .needsPicker(available.sorted())
        }
    }
}

@MainActor @Observable public final class ClinicBrowser {
    public private(set) var services: [String: NWEndpoint] = [:]
    @ObservationIgnored private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: KioskService.type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel(); browser = nil; services = [:]
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        services = Dictionary(results.compactMap { result in
            if case .service(let name, _, _, _) = result.endpoint { (name, result.endpoint) } else { nil }
        }, uniquingKeysWith: { first, _ in first })
    }
}
