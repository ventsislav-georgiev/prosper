import Foundation

/// Deterministic unit conversion for the command runner, built on Foundation's
/// `Measurement` / `Dimension`. Parses `"<n> <unit> to <unit>"` (also `in`,
/// `->`). Conversion only succeeds when both units share a category. Pure and
/// synchronous.
enum UnitConvert {

    struct Result {
        let value: Double
        let fromUnit: String
        let toUnit: String
        /// Pretty result, e.g. "525960 minutes".
        let formatted: String
    }

    /// A unit known to the converter, tagged by its category so we only convert
    /// within a category (length↔length, never length↔mass).
    private struct Entry {
        let category: String
        let unit: Dimension
        let display: String // canonical display name
    }

    /// Attempts a conversion. Returns nil if the input isn't a `<n> <unit> to
    /// <unit>` form or the units are incompatible.
    static func convert(_ input: String) -> Result? {
        guard let parsed = parse(input) else { return nil }
        guard let from = lookup(parsed.fromUnit), let to = lookup(parsed.toUnit) else { return nil }
        guard from.category == to.category else { return nil }

        let measurement = Measurement(value: parsed.value, unit: from.unit)
        let converted = measurement.converted(to: to.unit)
        let formatted = "\(Calc.format(converted.value)) \(to.display)"
        return Result(
            value: converted.value,
            fromUnit: from.display,
            toUnit: to.display,
            formatted: formatted
        )
    }

    // MARK: - Parsing

    private struct Parsed {
        let value: Double
        let fromUnit: String
        let toUnit: String
    }

    private static func parse(_ input: String) -> Parsed? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // Split on " to " / " in " / "->". Take the first separator occurrence.
        let separators = [" to ", " in ", "->", " → "]
        var lhs = "", rhs = ""
        var found = false
        for sep in separators {
            if let range = trimmed.range(of: sep) {
                lhs = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                rhs = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                found = true
                break
            }
        }
        guard found, !rhs.isEmpty else { return nil }

        // LHS = "<number> <unit>". Pull a leading number off the front.
        var numStr = ""
        var idx = lhs.startIndex
        while idx < lhs.endIndex {
            let c = lhs[idx]
            if c.isNumber || c == "." || c == "-" || c == "+" || c == "," || c == "_" {
                if c != "," && c != "_" { numStr.append(c) }
                idx = lhs.index(after: idx)
            } else {
                break
            }
        }
        guard let value = Double(numStr) else { return nil }
        let fromUnit = String(lhs[idx...]).trimmingCharacters(in: .whitespaces)
        guard !fromUnit.isEmpty else { return nil }
        return Parsed(value: value, fromUnit: fromUnit, toUnit: rhs)
    }

    // MARK: - Registry

    private static func lookup(_ raw: String) -> Entry? {
        let key = normalizeUnit(raw)
        return registry[key]
    }

    /// Strips a trailing plural "s" so "minutes" matches "minute".
    private static func normalizeUnit(_ raw: String) -> String {
        let k = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if k.count > 2, k.hasSuffix("s"), registry[String(k.dropLast())] != nil {
            return String(k.dropLast())
        }
        return k
    }

    /// Alias → Entry. Keys are singular/abbreviation forms; plurals handled by
    /// `normalizeUnit`.
    private static let registry: [String: Entry] = {
        var r: [String: Entry] = [:]
        func add(_ aliases: [String], _ category: String, _ unit: Dimension, _ display: String) {
            for a in aliases { r[a] = Entry(category: category, unit: unit, display: display) }
        }

        // Length
        add(["mm", "millimeter", "millimetre"], "length", UnitLength.millimeters, "mm")
        add(["cm", "centimeter", "centimetre"], "length", UnitLength.centimeters, "cm")
        add(["m", "meter", "metre"], "length", UnitLength.meters, "m")
        add(["km", "kilometer", "kilometre"], "length", UnitLength.kilometers, "km")
        add(["in", "inch", "\""], "length", UnitLength.inches, "in")
        add(["ft", "foot", "feet"], "length", UnitLength.feet, "ft")
        add(["yd", "yard"], "length", UnitLength.yards, "yd")
        add(["mi", "mile"], "length", UnitLength.miles, "mi")
        add(["nmi", "nauticalmile"], "length", UnitLength.nauticalMiles, "nmi")

        // Mass
        add(["mg", "milligram"], "mass", UnitMass.milligrams, "mg")
        add(["g", "gram", "gramme"], "mass", UnitMass.grams, "g")
        add(["kg", "kilogram"], "mass", UnitMass.kilograms, "kg")
        add(["t", "tonne", "metricton"], "mass", UnitMass.metricTons, "t")
        add(["oz", "ounce"], "mass", UnitMass.ounces, "oz")
        add(["lb", "lbs", "pound"], "mass", UnitMass.pounds, "lb")
        add(["st", "stone"], "mass", UnitMass.stones, "st")

        // Duration
        add(["ns", "nanosecond"], "duration", UnitDuration.nanoseconds, "ns")
        add(["us", "µs", "microsecond"], "duration", UnitDuration.microseconds, "µs")
        add(["ms", "millisecond"], "duration", UnitDuration.milliseconds, "ms")
        add(["s", "sec", "second"], "duration", UnitDuration.seconds, "seconds")
        add(["min", "minute"], "duration", UnitDuration.minutes, "minutes")
        add(["h", "hr", "hour"], "duration", UnitDuration.hours, "hours")
        // Custom durations beyond Foundation's built-ins (day/week/month/year).
        add(["day", "d"], "duration", customDuration(86_400), "days")
        add(["week", "wk"], "duration", customDuration(604_800), "weeks")
        add(["month", "mo"], "duration", customDuration(2_629_800), "months") // avg Gregorian month
        add(["year", "yr", "y"], "duration", customDuration(31_557_600), "years") // Julian year

        // Data
        add(["bit"], "data", UnitInformationStorage.bits, "bit")
        add(["byte", "b"], "data", UnitInformationStorage.bytes, "B")
        add(["kb", "kilobyte"], "data", UnitInformationStorage.kilobytes, "KB")
        add(["mb", "megabyte"], "data", UnitInformationStorage.megabytes, "MB")
        add(["gb", "gigabyte"], "data", UnitInformationStorage.gigabytes, "GB")
        add(["tb", "terabyte"], "data", UnitInformationStorage.terabytes, "TB")
        add(["kib"], "data", UnitInformationStorage.kibibytes, "KiB")
        add(["mib"], "data", UnitInformationStorage.mebibytes, "MiB")
        add(["gib"], "data", UnitInformationStorage.gibibytes, "GiB")

        // Temperature
        add(["c", "celsius", "°c"], "temp", UnitTemperature.celsius, "°C")
        add(["f", "fahrenheit", "°f"], "temp", UnitTemperature.fahrenheit, "°F")
        add(["k", "kelvin"], "temp", UnitTemperature.kelvin, "K")

        // Speed
        add(["mps", "m/s"], "speed", UnitSpeed.metersPerSecond, "m/s")
        add(["kph", "kmh", "km/h"], "speed", UnitSpeed.kilometersPerHour, "km/h")
        add(["mph"], "speed", UnitSpeed.milesPerHour, "mph")
        add(["knot", "kn"], "speed", UnitSpeed.knots, "kn")

        // Area
        add(["sqm", "m2", "squaremeter"], "area", UnitArea.squareMeters, "m²")
        add(["sqkm", "km2"], "area", UnitArea.squareKilometers, "km²")
        add(["sqft", "ft2"], "area", UnitArea.squareFeet, "ft²")
        add(["acre"], "area", UnitArea.acres, "acres")
        add(["hectare", "ha"], "area", UnitArea.hectares, "ha")

        // Volume
        add(["ml", "milliliter", "millilitre"], "volume", UnitVolume.milliliters, "mL")
        add(["l", "liter", "litre"], "volume", UnitVolume.liters, "L")
        add(["gal", "gallon"], "volume", UnitVolume.gallons, "gal")
        add(["pt", "pint"], "volume", UnitVolume.pints, "pt")
        add(["cup"], "volume", UnitVolume.cups, "cups")

        return r
    }()

    /// Builds a `UnitDuration` with a custom seconds-per-unit coefficient, for
    /// day/week/month/year which Foundation doesn't ship.
    private static func customDuration(_ secondsPerUnit: Double) -> UnitDuration {
        UnitDuration(symbol: "s", converter: UnitConverterLinear(coefficient: secondsPerUnit))
    }
}
