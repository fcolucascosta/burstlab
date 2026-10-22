import Foundation

/// Perceptual chroma adjustment after chroma denoising. Oklab matrices:
/// Bjorn Ottosson, https://bottosson.github.io/posts/oklab/ (public domain).
/// This is a rendering preference, separate from the DNG sensor calibration.
public enum BurstColorLook {
    struct Lab { let l: Double; let a: Double; let b: Double }

    static func toLab(_ r: Double, _ g: Double, _ b: Double) -> Lab {
        let l = cbrt(0.4122214708*r + 0.5363325363*g + 0.0514459929*b)
        let m = cbrt(0.2119034982*r + 0.6806995451*g + 0.1073969566*b)
        let s = cbrt(0.0883024619*r + 0.2817188376*g + 0.6299787005*b)
        return Lab(l: 0.2104542553*l + 0.7936177850*m - 0.0040720468*s,
                   a: 1.9779984951*l - 2.4285922050*m + 0.4505937099*s,
                   b: 0.0259040371*l + 0.7827717662*m - 0.8086757660*s)
    }

    static func fromLab(_ lab: Lab, chromaScale: Double) -> (Double, Double, Double) {
        let a = lab.a * chromaScale, b = lab.b * chromaScale
        let ll = lab.l + 0.3963377774*a + 0.2158037573*b
        let mm = lab.l - 0.1055613458*a - 0.0638541728*b
        let ss = lab.l - 0.0894841775*a - 1.2914855480*b
        let l = ll*ll*ll, m = mm*mm*mm, s = ss*ss*ss
        return (4.0767416621*l - 3.3077115913*m + 0.2309699292*s,
                -1.2684380046*l + 2.6097574011*m - 0.3413193965*s,
                -0.0041960863*l - 0.7034186147*m + 1.7076147010*s)
    }

    private static func smooth(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t*t*(3 - 2*t)
    }

    private static func inGamut(_ rgb: (Double, Double, Double)) -> Bool {
        rgb.0 >= -1e-7 && rgb.0 <= 1.0000001 && rgb.1 >= -1e-7 && rgb.1 <= 1.0000001
            && rgb.2 >= -1e-7 && rgb.2 <= 1.0000001
    }

    public static func apply(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        guard red.isFinite, green.isFinite, blue.isFinite else { return (0, 0, 0) }
        let r = min(max(red, 0), 1), g = min(max(green, 0), 1), b = min(max(blue, 0), 1)
        let lab = toLab(r, g, b)
        let chroma = hypot(lab.a, lab.b)
        guard chroma > 1e-6 else { return (r, g, b) }
        let luminance = 0.2126*r + 0.7152*g + 0.0722*b
        // Do not boost near-neutral fluctuations or the deepest shadow noise.
        let confidence = smooth((chroma - 0.006) / 0.018)
        let shadow = smooth((luminance - 0.004) / 0.036)
        let desired = 1 + 0.45 * (1 - 0.4 * min(chroma / 0.25, 1)) * confidence * shadow
        guard desired > 1.000001 else { return (r, g, b) }
        var output = fromLab(lab, chromaScale: desired)
        if !inGamut(output) {
            // Preserve Oklab lightness/hue; reduce only the requested chroma.
            var lo = 1.0, hi = desired
            for _ in 0..<10 {
                let mid = (lo + hi) / 2
                if inGamut(fromLab(lab, chromaScale: mid)) { lo = mid } else { hi = mid }
            }
            output = fromLab(lab, chromaScale: lo)
        }
        return (min(max(output.0, 0), 1), min(max(output.1, 0), 1), min(max(output.2, 0), 1))
    }
}
