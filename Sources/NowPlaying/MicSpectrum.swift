import Foundation
import AVFoundation
import Accelerate

/// Microphone-driven spectrum: taps the mic, runs an FFT, and exposes N smoothed band
/// magnitudes (0…1) for a bar graph. It reacts to whatever the mic hears — i.e. music
/// playing out loud in the room. (iOS can't tap another app's audio output, so the mic is
/// the only real-time source; with headphones there's nothing to analyze.)
///
/// Thread-safe: the audio tap runs on a realtime thread and writes the bands under a lock;
/// `bands` is read from the render loop on the main actor.
final class MicSpectrum {
    private let engine = AVAudioEngine()
    private let bandCount: Int
    private let fftSize = 1024
    private let log2n: vDSP_Length
    private var window: [Float]
    private var fftSetup: FFTSetup?

    private let lock = NSLock()
    private var _bands: [Float]
    private var running = false
    private var starting = false   // a permission request / capture start is in flight
    private var wantsRun = false   // the engine wants us live (cleared by stop())

    /// Surfaces capture problems (denied mic, no input device) to the UI.
    var onStatus: ((String) -> Void)?

    init(bandCount: Int = 16) {
        self.bandCount = bandCount
        self._bands = [Float](repeating: 0, count: bandCount)
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit { if let fftSetup { vDSP_destroy_fftsetup(fftSetup) } }

    /// Latest smoothed band magnitudes (0…1), left→right (low→high frequency).
    var bands: [Float] { lock.lock(); defer { lock.unlock() }; return _bands }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func start() {
        lock.lock()
        if running || starting { lock.unlock(); return }
        starting = true; wantsRun = true
        lock.unlock()

        // The mic needs explicit authorization. With the Apple Music source nothing else has
        // asked for it, so request here and only begin capturing once it's granted — otherwise
        // the input format comes back invalid and capture silently produces flat bars.
        Self.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            self.lock.lock(); let wanted = self.wantsRun; self.starting = false; self.lock.unlock()
            guard wanted else { return }
            guard granted else {
                self.onStatus?("Microphone access denied — enable it in Settings ▸ Privacy ▸ Microphone")
                return
            }
            DispatchQueue.main.async { self.beginCapture() }
        }
    }

    private func beginCapture() {
        lock.lock(); let wanted = wantsRun, already = running; lock.unlock()
        guard wanted, !already else { return }

        let session = AVAudioSession.sharedInstance()
        // Coexist with Apple Music: mix rather than interrupt; capture from the mic.
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onStatus?("No microphone input available")
            return
        }
        input.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: format) { [weak self] buf, _ in
            self?.process(buf)
        }
        engine.prepare()
        do {
            try engine.start()
            lock.lock(); running = true; lock.unlock()
        } catch {
            input.removeTap(onBus: 0)
            onStatus?("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    private static func requestRecordPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: completion)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(completion)
        }
    }

    func stop() {
        lock.lock(); let was = running; running = false; wantsRun = false
        _bands = [Float](repeating: 0, count: bandCount); lock.unlock()
        guard was else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], let fftSetup else { return }
        guard Int(buffer.frameLength) >= fftSize else { return }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(channel, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        // Group bins into log-spaced bands, convert to dB, normalize to 0…1.
        var out = [Float](repeating: 0, count: bandCount)
        let minBin = 1
        for b in 0..<bandCount {
            let lo = binFor(b, half, minBin)
            let hi = max(lo + 1, binFor(b + 1, half, minBin))
            var sum: Float = 0
            for k in lo..<min(hi, half) { sum += mags[k] }
            let avg = sum / Float(max(1, hi - lo))
            var v = 10 * log10f(avg + 1e-7)   // power → dB
            v = (v + 55) / 55                 // ~[-55…0] dB → [0…1]
            out[b] = max(0, min(1, v))
        }

        // Smooth: fast attack, slow decay (classic analyzer feel).
        lock.lock()
        if running {
            for i in 0..<bandCount {
                let prev = _bands[i]
                _bands[i] = out[i] > prev ? out[i] : prev * 0.72 + out[i] * 0.28
            }
        }
        lock.unlock()
    }

    private func binFor(_ b: Int, _ bins: Int, _ minBin: Int) -> Int {
        let t = Double(b) / Double(bandCount)
        let v = Double(minBin) * pow(Double(bins) / Double(minBin), t)
        return max(minBin, min(bins - 1, Int(v)))
    }
}
