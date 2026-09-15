import Foundation

enum NativeUnlockClient {
    private struct Lease: Decodable {
        let expiresAt: Double
    }

    private struct Failure: Decodable {
        let error: String
    }

    static func request(site: String, minutes: Int, reason: String) async throws -> Date {
        let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        try ScreenTimeStore.validateUserUnlock(site, minutes: minutes, reason: cleanReason)
        guard let origin = ScreenTimeStore.defaults.string(forKey: "connection.apiOrigin"),
              let token = ScreenTimeStore.defaults.string(forKey: "connection.sessionToken"),
              !token.isEmpty,
              let url = URL(string: origin + "/api/unlock")
        else { throw NativeError.connectionRequired }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "site": site,
            "minutes": minutes,
            "reason": cleanReason
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NativeError.reportingUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw NativeError.reportingUnavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                ScreenTimeStore.defaults.removeObject(forKey: "connection.sessionToken")
                throw NativeError.connectionRequired
            }
            let message = (try? JSONDecoder().decode(Failure.self, from: data).error)
            throw NativeError.server(message ?? "Telegram reporting failed. Apps stay blocked.")
        }
        guard let lease = try? JSONDecoder().decode(Lease.self, from: data),
              lease.expiresAt.isFinite else { throw NativeError.reportingUnavailable }
        return Date(timeIntervalSince1970: lease.expiresAt / 1000)
    }
}

extension ScreenTimeStore {
    static func requestUnlock(_ site: String, minutes: Int, reason: String) async throws -> Date {
        let expiry = try await NativeUnlockClient.request(site: site, minutes: minutes, reason: reason)
        _ = try unlock(site, until: expiry)
        return expiry
    }
}
