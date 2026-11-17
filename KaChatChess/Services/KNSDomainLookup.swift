import Foundation

/// What KNS said about a .kas domain, keeping "not registered" apart from "couldn't ask": a KNS
/// outage must read as "Couldn't check", never as a free name. The same three answers
/// `NameServicesClient` gives dotk and Kaspa Names (`getJSONOrMissing`).
enum KNSDomainLookup: Equatable {
    /// KNS answered 200 with the domain's owner.
    case found(KNSDomainResolution)
    /// KNS answered that the domain doesn't exist (404, or 200 with no owner for it).
    case missing
    /// No usable answer: a network error, a timeout, a 5xx or other non-200, a body that didn't
    /// decode, or an answer for another domain.
    case failed
}
