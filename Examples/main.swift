import PerunPGSQL

// Runnable, compile-checked examples that back the DocC documentation. Run one against a reachable
// PostgreSQL with `swift run Examples <scenario>` — connection settings come from the standard
// PG* environment variables (see Support.swift).

let scenario = CommandLine.arguments.dropFirst().first ?? ""
switch scenario {
case "basic-query":    try await runBasicQuery()
case "error-handling": try await runErrorHandling()
default:
    print("usage: swift run Examples <scenario>")
    print("scenarios: basic-query, error-handling")
}
