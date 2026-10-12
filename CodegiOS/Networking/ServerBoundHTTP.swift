import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The request is constructed from a fixed client before the await. A retired
/// generation cannot start another step or return data to a replacement view.
enum ServerBoundHTTP {
    static func perform(_ request: URLRequest, session: URLSession,
                        lifetime: ServerBindingLifetime?) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        try lifetime?.check()
        do {
            let result = try await session.data(for: request)
            try Task.checkCancellation()
            try lifetime?.check()
            return result
        } catch {
            try Task.checkCancellation()
            try lifetime?.check()
            throw error
        }
    }
}
