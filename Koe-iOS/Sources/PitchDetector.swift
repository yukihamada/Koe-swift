import Foundation
import Accelerate

/// Real-time pitch detection using autocorrelation via the Accelerate framework.
/// Detects fundamental frequency for voice (80Hz-2000Hz) and instruments.
/// Designed for integration with SolunaManager to send pitch data to STAGE.
final class PitchDetector {

    // Detection range
    private static let minFrequency: Float = 80    // low voice / bass
    private static let maxFrequency: Float = 2000  // high voice / instrument
    private static let silenceThreshold: Float = 0.01

    // Note names for display
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    // MARK: - Public API

    /// Detect fundamental frequency from PCM Float32 samples.
    /// Uses autocorrelation (fastest, most reliable for voice/instruments).
    /// - Parameters:
    ///   - samples: PCM Float32 audio buffer
    ///   - sampleRate: Sample rate in Hz (default 16000)
    /// - Returns: Detected frequency in Hz, or nil if no clear pitch (noise/silence)
    static func detectPitch(samples: [Float], sampleRate: Float = 16000) -> Float? {
        guard samples.count >= 512 else { return nil }

        // Check for silence — skip processing if signal is too quiet
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        guard rms > silenceThreshold else { return nil }

        // Step 1: Apply Hann window
        let n = samples.count
        var windowed = [Float](repeating: 0, count: n)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // Step 2: Autocorrelation via vDSP_conv
        // Correlation length = n, we compute lags from 0..n-1
        // vDSP_conv(signal, stride, filter, stride, result, stride, resultLength, filterLength)
        // For autocorrelation: correlate windowed with itself
        let resultLength = n
        var autocorr = [Float](repeating: 0, count: resultLength)

        // vDSP_conv requires filter to point to last element when using stride -1,
        // but for autocorrelation we use the direct approach:
        // R[lag] = sum(x[i] * x[i + lag]) for i in 0..<(n - lag)
        windowed.withUnsafeBufferPointer { sigBuf in
            guard let sigPtr = sigBuf.baseAddress else { return }
            for lag in 0..<resultLength {
                let len = vDSP_Length(n - lag)
                var dot: Float = 0
                vDSP_dotpr(sigPtr, 1, sigPtr + lag, 1, &dot, len)
                autocorr[lag] = dot
            }
        }

        // Normalize by autocorr[0]
        guard autocorr[0] > 0 else { return nil }
        var normFactor = 1.0 / autocorr[0]
        vDSP_vsmul(autocorr, 1, &normFactor, &autocorr, 1, vDSP_Length(resultLength))

        // Step 3: Find first peak after zero crossing
        // Lag range corresponding to our frequency range
        let minLag = max(1, Int(sampleRate / maxFrequency))
        let maxLag = min(resultLength - 1, Int(sampleRate / minFrequency))
        guard minLag < maxLag else { return nil }

        // Find the first significant peak in the autocorrelation
        var bestLag = 0
        var bestValue: Float = 0

        // Walk past the initial descent from lag=0, find where it goes negative or hits minimum
        var passedZero = false
        for lag in minLag...maxLag {
            if autocorr[lag] < 0 {
                passedZero = true
            }
            if passedZero && autocorr[lag] > bestValue {
                bestValue = autocorr[lag]
                bestLag = lag
            }
            // If we haven't crossed zero by minLag*2, look for local minimum instead
            if !passedZero && lag == minLag * 2 {
                passedZero = true
            }
        }

        // Require a reasonably strong peak (at least 0.2 correlation)
        guard bestLag > 0, bestValue > 0.2 else { return nil }

        // Step 4: Parabolic interpolation for sub-sample accuracy
        let refinedLag: Float
        if bestLag > 0 && bestLag < resultLength - 1 {
            let alpha = autocorr[bestLag - 1]
            let beta = autocorr[bestLag]
            let gamma = autocorr[bestLag + 1]
            let denom = alpha - 2 * beta + gamma
            if abs(denom) > 1e-10 {
                let delta = 0.5 * (alpha - gamma) / denom
                refinedLag = Float(bestLag) + delta
            } else {
                refinedLag = Float(bestLag)
            }
        } else {
            refinedLag = Float(bestLag)
        }

        let frequency = sampleRate / refinedLag

        // Validate within range
        guard frequency >= minFrequency, frequency <= maxFrequency else { return nil }

        return frequency
    }

    /// Convert frequency in Hz to MIDI note number.
    /// 69 = A4 (440Hz), 60 = C4 (middle C)
    static func hzToMidi(_ hz: Float) -> Int {
        guard hz > 0 else { return 0 }
        return Int(round(69.0 + 12.0 * log2(hz / 440.0)))
    }

    /// Convert frequency in Hz to note name with octave (e.g. "A4", "C#3").
    static func hzToNoteName(_ hz: Float) -> String {
        guard hz > 0 else { return "--" }
        let midi = hzToMidi(hz)
        let noteIndex = ((midi % 12) + 12) % 12
        let octave = (midi / 12) - 1
        return "\(noteNames[noteIndex])\(octave)"
    }

    /// Convenience: detect pitch and return note name, or nil.
    static func detectNoteName(samples: [Float], sampleRate: Float = 16000) -> String? {
        guard let hz = detectPitch(samples: samples, sampleRate: sampleRate) else { return nil }
        return hzToNoteName(hz)
    }
}
