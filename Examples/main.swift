import PerunPGSQL

// Runnable, compile-checked examples that back the DocC documentation. Run one against a reachable
// PostgreSQL with `swift run Examples <scenario>` — connection settings come from the standard
// PG* environment variables (see Support.swift).

let scenario = CommandLine.arguments.dropFirst().first ?? ""
switch scenario {
case "basic-query":    try await runBasicQuery()
case "error-handling": try await runErrorHandling()
case "transactions":   try await runTransactions()
case "pool":           try await runPool()
case "streaming":      try await runStreaming()
case "copy":           try await runCopy()
case "notifications":  try await runNotifications()
default:
    print("usage: swift run Examples <scenario>")
    print("scenarios: basic-query, error-handling, transactions, pool, streaming, copy, notifications")
}
