import Foundation

public enum BurstRAWDecoderSelection {
    /// Runtime decoder lists are not consistently newest-first on the SE.
    /// Only choose an actually returned numeric version, without downgrading
    /// a newer or unrecognized default. Prefer DNG at equal numeric rank.
    public static func newest(supported: [String], current: String) -> String {
        func rank(_ value: String) -> [Int]? {
            let text = value.hasSuffix(".dng") ? String(value.dropLast(4)) : value
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return nil }
            var numbers: [Int] = []
            for part in parts {
                guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let number = Int(part) else { return nil }
                numbers.append(number)
            }
            return numbers
        }
        func compare(_ a: [Int], _ b: [Int]) -> Int {
            for i in 0..<max(a.count, b.count) {
                let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
                if x != y { return x < y ? -1 : 1 }
            }
            return 0
        }
        guard let initial = rank(current) else { return current }
        var selected = current, best = initial
        for value in supported {
            guard let candidate = rank(value) else { continue }
            let order = compare(candidate, best)
            if order > 0 || (order == 0 && value.hasSuffix(".dng") && !selected.hasSuffix(".dng")) {
                best = candidate; selected = value
            }
        }
        return selected
    }
}
