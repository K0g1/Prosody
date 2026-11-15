import Foundation

public enum SafeURLValidationError: Error, Equatable, Sendable {
    case malformed
    case unsupportedScheme(String)
    case missingHost
    case credentialsNotAllowed
    case insecureRemoteHTTP
    case remoteAccessDisabled
}

public struct SafeURLPolicy: Sendable, Equatable {
    public var localOnly: Bool

    public init(localOnly: Bool = false) {
        self.localOnly = localOnly
    }
}

/// Validates provider endpoints before they are handed to URLSession.
///
/// Plain HTTP is limited to loopback. Remote endpoints must use HTTPS, and
/// local-only mode rejects every non-loopback host regardless of scheme.
public enum SafeURLValidator {
    public static let loopbackHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
        "::1"
    ]

    public static func validate(_ string: String, policy: SafeURLPolicy = SafeURLPolicy()) throws -> URL {
        guard let url = URL(string: string) else { throw SafeURLValidationError.malformed }
        return try validate(url, policy: policy)
    }

    public static func validate(_ url: URL, policy: SafeURLPolicy = SafeURLPolicy()) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw SafeURLValidationError.malformed
        }
        guard scheme == "http" || scheme == "https" else {
            throw SafeURLValidationError.unsupportedScheme(scheme)
        }
        guard let rawHost = url.host, !rawHost.isEmpty else {
            throw SafeURLValidationError.missingHost
        }
        guard url.user == nil && url.password == nil else {
            throw SafeURLValidationError.credentialsNotAllowed
        }

        let host = normalizedHost(rawHost)
        let isLoopback = loopbackHosts.contains(host)

        if policy.localOnly && !isLoopback {
            throw SafeURLValidationError.remoteAccessDisabled
        }
        if scheme == "http" && !isLoopback {
            throw SafeURLValidationError.insecureRemoteHTTP
        }

        return url
    }

    public static func isAllowed(_ url: URL, policy: SafeURLPolicy = SafeURLPolicy()) -> Bool {
        (try? validate(url, policy: policy)) != nil
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        loopbackHosts.contains(normalizedHost(host))
    }

    private static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }
}
