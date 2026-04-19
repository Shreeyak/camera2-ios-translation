import Foundation

public enum SessionState: String, Sendable, Hashable {
    case opening
    case streaming
    case recovering
    case paused
    case error
    case closed
}

public enum RecordingState: String, Sendable, Hashable {
    case idle
    case preparing
    case recording
    case stopping
}

public enum StreamId: String, Sendable, Hashable, CaseIterable {
    case natural
    case processed
    case tracker
}
