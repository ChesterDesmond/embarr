import Foundation

/// What the mug is running: its settings, and which program they came from (nil for the slider or Turn off).
public struct Running: Equatable, Sendable {
    public var mode: Mode
    public var presetID: UUID?
    public init(mode: Mode, presetID: UUID?) { self.mode = mode; self.presetID = presetID }
}

/// A tap on a program tile. It starts the program and remembers what it replaced; tapped again while it runs, it
/// goes back to that, so a mistaken tap is undone by tapping again.
public enum ProgramTap {
    /// - Parameters:
    ///   - now: what is running at the tap.
    ///   - before: what the last tap replaced; nil when there is nothing to go back to (e.g. after a relaunch), in
    ///     which case going back means heater off.
    ///   - presets: the saved programs, so a remembered program that was edited or deleted since comes back as
    ///     plain settings rather than lighting a tile that no longer matches.
    public static func tap(_ p: Preset, now: Running, before: Running?, presets: [Preset]) -> (next: Running, before: Running?) {
        guard p.isRunning(chosen: now.presetID, current: now.mode) else {
            return (Running(mode: p.mode, presetID: p.id), now)
        }
        var back = before ?? Running(mode: .off, presetID: nil)
        if let id = back.presetID, !presets.contains(where: { $0.isRunning(chosen: id, current: back.mode) }) {
            back.presetID = nil
        }
        return (back, nil)
    }
}

/// Programs saved to a file to share with another Embarr user. The file holds the programs only, never which
/// mug this Mac is paired with or how it has learned to heat. Its layout is spelled out here rather than derived from
/// `Mode`, so a file already sent keeps importing however `Mode` changes later.
public struct ProgramFile: Codable, Equatable, Sendable {
    // Kept from before the rename to Embarr, so files already shared still import.
    public static let format = "Ember Bar programs"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var programs: [Entry]

    /// One program: `kind` is "hold", "glide" or "off"; temperatures are Celsius.
    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        public var kind: String
        public var celsius: Double?
        public var steps: [Step]?
        public var light: EmberCodec.RGB?

        public struct Step: Codable, Equatable, Sendable {
            public var celsius: Double
            /// Nil: hold this step until the mug is empty.
            public var minutes: Double?
        }
    }

    public enum Problem: Error, Equatable {
        case notAProgramFile
        case newerVersion
        case noPrograms
    }

    public static func encode(_ programs: [Preset]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(ProgramFile(format: format, version: currentVersion, programs: programs.map(entry)))
    }

    /// Reads a shared file. Programs come back with new ids (so importing twice can't make two tiles light
    /// together), names trimmed, temperatures and step lengths kept inside what the editor offers. An entry this
    /// version can't read (an unknown kind, a missing field) is dropped, and the rest still import.
    public static func decode(_ data: Data) throws -> [Preset] {
        struct Header: Decodable { let format: String; let version: Int }
        guard let head = try? JSONDecoder().decode(Header.self, from: data), head.format == format else {
            throw Problem.notAProgramFile
        }
        guard head.version <= currentVersion else { throw Problem.newerVersion }
        // Each entry decodes on its own, so one bad entry doesn't sink the file.
        struct Lenient: Decodable {
            let entry: Entry?
            init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
        }
        struct Body: Decodable { let programs: [Lenient] }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw Problem.notAProgramFile }
        let programs = body.programs.compactMap { $0.entry }.compactMap(preset)
        guard !programs.isEmpty else { throw Problem.noPrograms }
        return programs
    }

    /// Adds `incoming` after `existing`, skipping any that match a saved program in both name and heating settings
    /// (the light color is not compared).
    public static func merge(_ incoming: [Preset], into existing: [Preset]) -> (programs: [Preset], added: Int, skipped: Int) {
        var out = existing
        var skipped = 0
        for p in incoming {
            if out.contains(where: { $0.name == p.name && $0.mode == p.mode }) { skipped += 1 } else { out.append(p) }
        }
        return (out, out.count - existing.count, skipped)
    }

    static func entry(_ p: Preset) -> Entry {
        switch p.mode {
        case .off: Entry(name: p.name, kind: "off", light: p.light)
        case .hold(let t): Entry(name: p.name, kind: "hold", celsius: t, light: p.light)
        case .glide(let steps):
            Entry(name: p.name, kind: "glide", steps: steps.map { .init(celsius: $0.target, minutes: $0.minutes) }, light: p.light)
        }
    }

    static func preset(_ e: Entry) -> Preset? {
        func temp(_ t: Double) -> Double { min(max(t, MugLimits.sliderFloor), MugLimits.ceiling) }
        let mode: Mode
        switch e.kind {
        case "off": mode = .off
        case "hold":
            guard let t = e.celsius else { return nil }
            mode = .hold(temp(t))
        case "glide":
            guard let steps = e.steps, !steps.isEmpty else { return nil }
            // Whole minutes, 1 to 120, as the editor allows; only the last step may run until the mug is empty.
            mode = .glide(steps.enumerated().map { i, st in
                let m = st.minutes ?? (i == steps.count - 1 ? nil : 10)
                return GlideStep(target: temp(st.celsius), minutes: m.map { min(max($0.rounded(), 1), 120) })
            })
        default: return nil
        }
        return Preset(name: Preset.cleanName(e.name) ?? "Imported program", mode: mode, light: e.light)
    }
}
