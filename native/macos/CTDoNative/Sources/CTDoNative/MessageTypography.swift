import SwiftUI

/// Matches the flat inline markers accepted by the Rust textProperties encoder.
enum MessageTypography {
    private final class Entry:NSObject {let value:AttributedString;init(_ value:AttributedString){self.value=value}}
    private static let expression=try? NSRegularExpression(pattern:#"(\*\*|__|~~|\*)(.+?)\1"#)
    private static let cache:NSCache<NSString,Entry> = {let cache=NSCache<NSString,Entry>();cache.countLimit=2000;cache.totalCostLimit=4*1024*1024;return cache}()
    static func inline(_ text:String)->AttributedString {
        if let cached=cache.object(forKey:text as NSString){return cached.value}
        guard let pattern=expression else{return AttributedString(text)}
        let source=text as NSString
        var result=AttributedString(),offset=0
        for match in pattern.matches(in:text,range:NSRange(location:0,length:source.length)) {
            result += AttributedString(source.substring(with:NSRange(location:offset,length:match.range.location-offset)))
            var run=AttributedString(source.substring(with:match.range(at:2)))
            switch source.substring(with:match.range(at:1)) {
            case "**":run.font = .system(size:MessageTextSize.size(14),weight:.bold)
            case "*":run.font = .system(size:MessageTextSize.size(14)).italic()
            case "__":run.underlineStyle = Text.LineStyle(pattern:.solid)
            case "~~":run.strikethroughStyle = Text.LineStyle(pattern:.solid)
            default:break
            }
            result += run;offset=match.range.location+match.range.length
        }
        result += AttributedString(source.substring(from:offset))
        cache.setObject(Entry(result),forKey:text as NSString,cost:text.utf8.count*4)
        return result
    }

    /// "@All" and "@Name Surname" tags. Zalo sends mention offsets the worker does not keep, so names
    /// are recognised as an at sign followed by up to four capitalised words.
    private static let mentionPattern = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])@(?:All\b|[\p{Lu}][\p{L}\p{M}]*(?:[ \u00A0][\p{Lu}][\p{L}\p{M}]*){0,3})"#)

    static func hasMention(_ text: String) -> Bool {
        guard text.contains("@"), let mentionPattern else { return false }
        return mentionPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Message text with tagged names set apart from the words around them.
    static func withMentions(_ text: String, outgoing: Bool) -> AttributedString {
        var result = inline(text)
        guard hasMention(text), let mentionPattern else { return result }
        let plain = String(result.characters)
        let source = plain as NSString
        for match in mentionPattern.matches(in: plain, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            // Same size and weight as the words around it; only colour sets the tag apart.
            result[lower..<upper].foregroundColor = outgoing ? .white : .accentColor
            if outgoing { result[lower..<upper].backgroundColor = Color.white.opacity(0.18) }
        }
        return result
    }
}
