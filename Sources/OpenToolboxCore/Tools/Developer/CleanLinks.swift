import Foundation

/// Removes tracking parameters from URLs and unwraps common redirect wrappers.
public enum CleanLinks {
    public struct Result: Equatable, Sendable {
        public var original: String
        public var cleaned: String
        /// Query parameter names that were removed.
        public var removedParameters: [String]
        /// `true` when a redirect wrapper (for example a search-result link) was unwrapped.
        public var unwrapped: Bool

        public var changed: Bool { original != cleaned }
    }

    /// Parameter names removed everywhere (compared case-insensitively).
    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "igshid", "igsh", "mc_cid", "mc_eid", "mkt_tok", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp",
        "hsctatracking", "vero_id", "vero_conv", "oly_anon_id", "oly_enc_id", "rb_clickid", "s_cid",
        "li_fat_id", "ref_src", "ref_url", "spm", "scm", "_openstat", "wickedid", "srsltid", "si",
        "trk", "trkCampaign", "sc_campaign", "sc_channel", "sc_content", "sc_medium", "sc_outcome",
        "sc_geo", "sc_country", "cmpid", "ncid", "guccounter", "guce_referrer", "guce_referrer_sig",
    ]

    /// Parameter name prefixes removed everywhere.
    static let trackingPrefixes: [String] = ["utm_", "pk_", "mtm_", "hsa_", "ga_", "itm_"]

    /// Hosts whose links wrap another URL in a query parameter.
    static let redirectWrappers: [(host: String, path: String, parameter: String)] = [
        ("www.google.com", "/url", "q"),
        ("www.google.com", "/url", "url"),
        ("google.com", "/url", "q"),
        ("l.facebook.com", "/l.php", "u"),
        ("lm.facebook.com", "/l.php", "u"),
        ("l.instagram.com", "/", "u"),
        ("out.reddit.com", "/", "url"),
        ("www.youtube.com", "/redirect", "q"),
        ("t.umblr.com", "/redirect", "z"),
        ("steamcommunity.com", "/linkfilter/", "url"),
    ]

    public static func isTrackingParameter(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return trackingParameters.contains { $0.lowercased() == lowered }
            || trackingPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// Cleans a single URL string. Non-HTTP(S) input is returned unchanged.
    public static func clean(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            return Result(original: text, cleaned: text, removedParameters: [], unwrapped: false)
        }

        var unwrapped = false
        // Unwrap nested redirect wrappers (bounded to avoid loops).
        for _ in 0..<3 {
            guard let target = redirectTarget(of: components), let inner = URLComponents(string: target) else { break }
            components = inner
            unwrapped = true
        }

        var removed: [String] = []
        if let items = components.percentEncodedQueryItems {
            let kept = items.filter { item in
                if isTrackingParameter(item.name) {
                    removed.append(item.name)
                    return false
                }
                return true
            }
            components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        }
        if let fragment = components.fragment, fragment.hasPrefix(":~:text=") || fragment.lowercased().hasPrefix("utm_") {
            // Text fragments and fragment-encoded campaign tags are tracking-like noise.
            components.fragment = nil
            removed.append("#" + (fragment.split(separator: "=").first.map(String.init) ?? fragment))
        }
        let cleaned = components.string ?? trimmed
        return Result(original: text, cleaned: cleaned, removedParameters: removed, unwrapped: unwrapped)
    }

    /// Cleans every http(s) URL found in free text, keeping the surrounding text.
    public static func cleanAll(in text: String) -> (text: String, results: [Result]) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return (text, [])
        }
        let nsText = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var output = text
        var results: [Result] = []
        // Replace from the end so earlier ranges stay valid.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let original = String(output[range])
            guard original.lowercased().hasPrefix("http://") || original.lowercased().hasPrefix("https://") else {
                continue
            }
            let result = clean(original)
            results.insert(result, at: 0)
            if result.changed { output.replaceSubrange(range, with: result.cleaned) }
        }
        return (output, results)
    }

    private static func redirectTarget(of components: URLComponents) -> String? {
        guard let host = components.host?.lowercased() else { return nil }
        let path = components.path.isEmpty ? "/" : components.path
        for wrapper in redirectWrappers where wrapper.host == host && path == wrapper.path {
            if let value = components.queryItems?.first(where: { $0.name == wrapper.parameter })?.value,
                let scheme = URLComponents(string: value)?.scheme?.lowercased(), scheme == "http" || scheme == "https"
            {
                return value
            }
        }
        return nil
    }
}
