/// An asynchronous `LISTEN`/`NOTIFY` notification pushed by the server.
public struct PostgresNotification: Sendable {
    /// PID of the backend that issued the `NOTIFY`.
    public let processID: Int32
    /// The channel the notification was sent on.
    public let channel: String
    /// The optional payload string (empty if none was given).
    public let payload: String
}
