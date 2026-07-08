import Foundation

/// SASLprep (RFC 4013) preparation of a SCRAM password.
///
/// Mirrors PostgreSQL's `pg_saslprep`, which is the interop authority: it maps a few
/// code points, applies Unicode normalization form KC, and rejects prohibited output —
/// but on *any* failure it falls back to the original string, exactly as libpq and the
/// PostgreSQL server do, so both sides derive the same key. Pure ASCII (the common case)
/// is returned unchanged.
///
/// Like `pg_saslprep`, this deliberately skips RFC 3454's bidirectional check (section 6)
/// and the unassigned-code-point check (table A.1): applying them would reject strings
/// PostgreSQL accepts and so break authentication. NFKC comes from Foundation; the mapping
/// and prohibited-output tables come from `Unicode.Scalar.Properties` plus the small fixed
/// sets below.
func saslPrep(_ input: String) -> String {
    // Pure ASCII is never changed: nothing maps or normalizes, and a prohibited ASCII
    // control would fall back to the original in any case.
    if input.unicodeScalars.allSatisfy({ $0.value < 0x80 }) { return input }

    // 1. Mapping (RFC 3454 tables B.1 and C.1.2): drop the "commonly mapped to nothing"
    //    code points, and turn every non-ASCII space into U+0020.
    var mapped = String.UnicodeScalarView()
    for scalar in input.unicodeScalars {
        if saslPrepMappedToNothing.contains(scalar.value) { continue }
        if scalar.properties.generalCategory == .spaceSeparator {
            mapped.append(" ")
        } else {
            mapped.append(scalar)
        }
    }

    // 2. Normalization: Unicode NFKC.
    let normalized = String(mapped).precomposedStringWithCompatibilityMapping

    // 3. Prohibited output → fall back to the original password (as PostgreSQL does).
    if normalized.unicodeScalars.contains(where: saslPrepIsProhibited) {
        return input
    }
    return normalized
}

/// RFC 3454 table B.1 — "commonly mapped to nothing".
private let saslPrepMappedToNothing: Set<UInt32> = [
    0x00AD, 0x034F, 0x1806, 0x180B, 0x180C, 0x180D,
    0x200B, 0x200C, 0x200D, 0x2060,
    0xFE00, 0xFE01, 0xFE02, 0xFE03, 0xFE04, 0xFE05, 0xFE06, 0xFE07,
    0xFE08, 0xFE09, 0xFE0A, 0xFE0B, 0xFE0C, 0xFE0D, 0xFE0E, 0xFE0F,
    0xFEFF,
]

/// The prohibited-output tables (RFC 3454 C.2.1, C.2.2, C.3–C.9), expressed through Unicode
/// general categories plus the two ranges that aren't a whole category. Non-ASCII spaces
/// (C.1.2) never reach here — they were mapped to U+0020 above.
private func saslPrepIsProhibited(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control,            // C.2.1 ASCII control, C.2.2 non-ASCII control
         .format,             // C.2.2 / C.8 / C.9 formatting and tag characters
         .privateUse,         // C.3 private use
         .surrogate,          // C.5 surrogates (unreachable in a Swift String)
         .lineSeparator,      // C.2.2 U+2028
         .paragraphSeparator: // C.2.2 U+2029
        return true
    default:
        break
    }
    if scalar.properties.isNoncharacterCodePoint { return true }   // C.4 non-character code points
    switch scalar.value {
    case 0x2FF0 ... 0x2FFB: return true   // C.7 inappropriate for canonical representation
    case 0xFFF9 ... 0xFFFD: return true   // C.6 inappropriate for plain text
    default: return false
    }
}
