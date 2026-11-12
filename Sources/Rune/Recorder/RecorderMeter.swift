import Foundation

/// Meter ballistics shared by the fake microphone and the macOS backend (`recorder::meter`).
public enum RecorderMeterConstants {
    /// The quietest level a meter reports, in dBFS, as AVAudioRecorder does.
    public static let floorDB: Float = -160.0
    /// The level `Level.meter()` maps to 0.
    public static let meterFloorDB: Float = -60.0
    /// RMS rise time constant (seconds).
    public static let attackSeconds: Double = 0.03
    /// RMS fall time constant (seconds).
    public static let releaseSeconds: Double = 0.3
    /// Peak fall rate in dB per second.
    public static let peakFallDBPerSecond: Double = 20.0
}

/// An input level, smoothed like a meter: peak jumps up immediately and falls at 20 dB/s,
/// while RMS rises over ~30 ms and falls over ~300 ms. Silence is -160 dBFS.
public struct Level: Sendable, Equatable, Hashable {
    public let _peakDB: Float
    public let _rmsDB: Float

    /// No input.
    public static let silent = Level(peakDB: RecorderMeterConstants.floorDB, rmsDB: RecorderMeterConstants.floorDB)

    public init(peakDB: Float, rmsDB: Float) {
        self._peakDB = min(0.0, max(RecorderMeterConstants.floorDB, peakDB.isNaN ? RecorderMeterConstants.floorDB : peakDB))
        self._rmsDB = min(0.0, max(RecorderMeterConstants.floorDB, rmsDB.isNaN ? RecorderMeterConstants.floorDB : rmsDB))
    }

    public static func new(_ peakDB: Float, _ rmsDB: Float) -> Level {
        Level(peakDB: peakDB, rmsDB: rmsDB)
    }

    /// The smoothed peak sample in dBFS (-160 to 0).
    public func peakDB() -> Float { _peakDB }

    /// The smoothed RMS in dBFS (-160 to 0). A full-scale sine reads about -3.
    public func rmsDB() -> Float { _rmsDB }

    /// The RMS for a level bar: -60 dBFS and below is 0, full scale is 1.
    public func meter() -> Float {
        let floor = RecorderMeterConstants.meterFloorDB
        let normalized = (_rmsDB - floor) / -floor
        return min(1.0, max(0.0, normalized))
    }
}

/// Smooths raw block measurements into a `Level`.
public struct RecorderMeter: Sendable {
    private var peakDB: Double
    private var ms: Double

    public init() {
        self.peakDB = Double(RecorderMeterConstants.floorDB)
        self.ms = 0.0
    }

    /// Folds in one block lasting `dt` seconds: its peak amplitude and mean square.
    public mutating func push(peak: Double, meanSquare: Double, dt: Double) {
        guard dt > 0.0 else { return }
        let floor = Double(RecorderMeterConstants.floorDB)
        let msClean = meanSquare.isFinite ? max(0.0, meanSquare) : 0.0
        let tau = msClean > ms ? RecorderMeterConstants.attackSeconds : RecorderMeterConstants.releaseSeconds
        ms += (msClean - ms) * (1.0 - exp(-dt / tau))

        let pDB: Double
        if peak.isFinite {
            let amp = abs(peak)
            pDB = amp > 0.0 ? max(floor, 20.0 * log10(amp)) : floor
        } else {
            pDB = floor
        }
        peakDB = max(floor, max(pDB, peakDB - RecorderMeterConstants.peakFallDBPerSecond * dt))
    }

    /// Folds in a block measured in dBFS, as AVAudioRecorder reports it.
    public mutating func pushDB(peakDB: Float, rmsDB: Float, dt: Double) {
        func amplitude(_ db: Float) -> Double {
            if db.isFinite && db > RecorderMeterConstants.floorDB {
                return pow(10.0, Double(db) / 20.0)
            }
            return 0.0
        }
        let rms = amplitude(rmsDB)
        push(peak: amplitude(peakDB), meanSquare: rms * rms, dt: dt)
    }

    /// Folds in a block of samples lasting `samples.count / rate` seconds.
    public mutating func pushSamples(_ samples: [Float], rate: UInt32) {
        guard !samples.isEmpty else { return }
        var peak: Double = 0
        var sum: Double = 0
        for s in samples {
            let v = s.isFinite ? Double(s) : 0.0
            peak = max(peak, abs(v))
            sum += v * v
        }
        push(peak: peak, meanSquare: sum / Double(samples.count), dt: Double(samples.count) / Double(max(1, rate)))
    }

    public mutating func pushSamples(rate: UInt32, count: Int, sampleAt: (Int) -> Float) {
        guard count > 0 else { return }
        var peak: Double = 0
        var sum: Double = 0
        for i in 0..<count {
            let raw = sampleAt(i)
            let v = raw.isFinite ? Double(raw) : 0.0
            peak = max(peak, abs(v))
            sum += v * v
        }
        push(peak: peak, meanSquare: sum / Double(count), dt: Double(count) / Double(max(1, rate)))
    }

    public func level() -> Level {
        let floor = Double(RecorderMeterConstants.floorDB)
        let rmsDB = ms > 0.0 ? max(floor, 10.0 * log10(ms)) : floor
        return Level(peakDB: Float(peakDB), rmsDB: Float(rmsDB))
    }
}
