# LISTEN / NOTIFY

Receiving asynchronous notifications from the server.

## Subscribing

``PostgresConnection/listen(to:)`` subscribes a connection to a channel; notifications then arrive
on its ``PostgresConnection/notifications`` async stream as ``PostgresNotification`` values:

```swift
try await connection.listen(to: "events")

for await note in connection.notifications {
    print("channel \(note.channel): \(note.payload)")
}
```

A ``PostgresNotification`` carries the `channel`, the `payload` string (empty if none was given),
and the `processID` of the backend that issued the `NOTIFY`. ``PostgresConnection/unlisten(from:)``
unsubscribes.

## Driving delivery

Notifications are pushed by the server, but the driver only sees them when it reads the
connection: they ride along on ordinary query traffic. To receive them on an otherwise-idle
connection, call ``PostgresConnection/waitForNotifications()``, which reads until the task is
cancelled or the connection closes:

```swift
try await listener.listen(to: "events")

let pump = Task { try? await listener.waitForNotifications() }
for await note in listener.notifications {
    handle(note)
    if done { break }
}
pump.cancel()
```

`waitForNotifications()` holds the wire exclusively for its whole duration, so reserve a
connection for listening rather than sharing it with queries.

## Notices

Server `NoticeResponse` messages (warnings and the like) are separate from notifications; register
a handler for them with ``PostgresConnection/onNotice(_:)``.
