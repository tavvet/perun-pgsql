import PerunPGSQL

/// LISTEN on one connection, NOTIFY from another, and receive the notification.
func runNotifications() async throws {
    let listener = try await PostgresConnection.connect(exampleConfiguration())
    defer { Task { try? await listener.close() } }
    let notifier = try await PostgresConnection.connect(exampleConfiguration())
    defer { Task { try? await notifier.close() } }

    try await listener.listen(to: "events")

    // Drive delivery on the (otherwise idle) listener, and read the first notification.
    let pump = Task { try? await listener.waitForNotifications() }
    let received = Task { () -> PostgresNotification? in
        for await note in listener.notifications { return note }
        return nil
    }

    try await Task.sleep(for: .milliseconds(100))
    _ = try await notifier.query("NOTIFY events, 'hello'")

    if let note = await received.value {
        print("received on '\(note.channel)': \(note.payload)")
    }
    pump.cancel()
}
