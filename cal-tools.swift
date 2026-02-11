import Foundation
import EventKit

// MARK: - JSON Output Helpers

func jsonString(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func exitSuccess(_ payload: [String: Any]) -> Never {
    var out = payload
    out["ok"] = true
    if let s = try? jsonString(out) {
        print(s)
    }
    exit(0)
}

func exitError(_ message: String) -> Never {
    let payload: [String: Any] = ["ok": false, "error": message]
    if let s = try? jsonString(payload) {
        FileHandle.standardError.write(s.data(using: .utf8)!)
    }
    exit(1)
}

// MARK: - Date Parsing

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

let isoFormatterNoTZ: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone.current
    return f
}()

let dateOnlyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
}()

let outputFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func parseDate(_ string: String) -> Date? {
    // Try full ISO 8601 with timezone first
    if let d = isoFormatter.date(from: string) { return d }
    // Try ISO 8601 without timezone (assume local)
    // Append local timezone offset for parsing
    if string.count == 19 { // "2026-02-15T10:00:00"
        let withZ = string + TimeZone.current.iso8601Offset()
        if let d = isoFormatter.date(from: withZ) { return d }
    }
    // Try date-only format
    if let d = dateOnlyFormatter.date(from: string) { return d }
    return nil
}

extension TimeZone {
    func iso8601Offset() -> String {
        let seconds = self.secondsFromGMT()
        let hours = abs(seconds) / 3600
        let minutes = (abs(seconds) % 3600) / 60
        let sign = seconds >= 0 ? "+" : "-"
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }
}

func startOfDay(_ date: Date) -> Date {
    return Calendar.current.startOfDay(for: date)
}

func endOfDay(_ date: Date) -> Date {
    var comps = DateComponents()
    comps.day = 1
    comps.second = -1
    return Calendar.current.date(byAdding: comps, to: startOfDay(date))!
}

// MARK: - Event Serialization

func serializeEvent(_ event: EKEvent) -> [String: Any] {
    var dict: [String: Any] = [
        "id": event.eventIdentifier ?? "",
        "title": event.title ?? "(No Title)",
        "start": outputFormatter.string(from: event.startDate),
        "end": outputFormatter.string(from: event.endDate),
        "allDay": event.isAllDay,
        "calendar": event.calendar?.title ?? "",
        "location": event.location ?? "",
        "notes": event.notes ?? "",
        "url": event.url?.absoluteString ?? "",
    ]

    // Attendees
    var attendeeList: [String] = []
    if let attendees = event.attendees {
        for a in attendees {
            if let email = a.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                .removingPercentEncoding {
                attendeeList.append(email)
            }
        }
    }
    dict["attendees"] = attendeeList

    // Recurrence rules
    if let rules = event.recurrenceRules, !rules.isEmpty {
        // Build a simplified RRULE-like string
        var parts: [String] = []
        for rule in rules {
            var ruleStr = ""
            switch rule.frequency {
            case .daily: ruleStr = "FREQ=DAILY"
            case .weekly: ruleStr = "FREQ=WEEKLY"
            case .monthly: ruleStr = "FREQ=MONTHLY"
            case .yearly: ruleStr = "FREQ=YEARLY"
            @unknown default: ruleStr = "FREQ=UNKNOWN"
            }
            if rule.interval > 1 {
                ruleStr += ";INTERVAL=\(rule.interval)"
            }
            parts.append(ruleStr)
        }
        dict["recurrenceRule"] = parts.joined(separator: " | ")
    } else {
        dict["recurrenceRule"] = ""
    }

    // Availability
    switch event.availability {
    case .busy: dict["availability"] = "busy"
    case .free: dict["availability"] = "free"
    case .tentative: dict["availability"] = "tentative"
    case .unavailable: dict["availability"] = "unavailable"
    case .notSupported: dict["availability"] = "notSupported"
    @unknown default: dict["availability"] = "unknown"
    }

    // Status
    switch event.status {
    case .none: dict["status"] = "none"
    case .confirmed: dict["status"] = "confirmed"
    case .tentative: dict["status"] = "tentative"
    case .canceled: dict["status"] = "canceled"
    @unknown default: dict["status"] = "unknown"
    }

    return dict
}

func serializeCalendar(_ cal: EKCalendar) -> [String: Any] {
    var typeStr: String
    switch cal.type {
    case .local: typeStr = "local"
    case .calDAV: typeStr = "calDAV"
    case .exchange: typeStr = "exchange"
    case .subscription: typeStr = "subscription"
    case .birthday: typeStr = "birthday"
    @unknown default: typeStr = "unknown"
    }

    let cgColor = cal.cgColor
    var colorHex = ""
    if let color = cgColor {
        let ciColor = CIColor(cgColor: color)
        let r = Int(ciColor.red * 255)
        let g = Int(ciColor.green * 255)
        let b = Int(ciColor.blue * 255)
        colorHex = String(format: "#%02X%02X%02X", r, g, b)
    }

    return [
        "id": cal.calendarIdentifier,
        "title": cal.title,
        "type": typeStr,
        "source": cal.source?.title ?? "",
        "color": colorHex,
        "immutable": cal.isImmutable,
    ]
}

// MARK: - Argument Parsing

class Args {
    let args: [String]

    init() {
        self.args = Array(CommandLine.arguments.dropFirst()) // drop binary name
    }

    var subcommand: String? {
        return args.first
    }

    var rest: [String] {
        return Array(args.dropFirst())
    }

    func flag(_ name: String) -> Bool {
        return rest.contains("--\(name)")
    }

    func value(_ name: String) -> String? {
        guard let idx = rest.firstIndex(of: "--\(name)"), idx + 1 < rest.count else {
            return nil
        }
        return rest[idx + 1]
    }
}

// MARK: - Commands

func cmdCalendars(store: EKEventStore) {
    let calendars = store.calendars(for: .event)
    let serialized = calendars.map { serializeCalendar($0) }
    exitSuccess(["calendars": serialized])
}

func cmdEvents(store: EKEventStore, args: Args) {
    var startDate: Date
    var endDate: Date

    if args.flag("today") {
        startDate = startOfDay(Date())
        endDate = endOfDay(Date())
    } else if let daysStr = args.value("days"), let days = Int(daysStr), days > 0 {
        startDate = startOfDay(Date())
        endDate = endOfDay(Calendar.current.date(byAdding: .day, value: days - 1, to: Date())!)
    } else if let daysStr = args.value("past-days"), let days = Int(daysStr), days > 0 {
        startDate = startOfDay(Calendar.current.date(byAdding: .day, value: -days, to: Date())!)
        endDate = endOfDay(Date())
    } else if let fromStr = args.value("from"), let toStr = args.value("to") {
        guard let from = parseDate(fromStr) else {
            exitError("Invalid --from date: \(fromStr). Use ISO 8601 format (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS).")
        }
        guard let to = parseDate(toStr) else {
            exitError("Invalid --to date: \(toStr). Use ISO 8601 format (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS).")
        }
        startDate = from
        endDate = to
    } else {
        exitError("Provide a date range: --today, --days N, --past-days N, or --from/--to dates.")
    }

    var calendars: [EKCalendar]? = nil
    if let calName = args.value("calendar") {
        let all = store.calendars(for: .event)
        let matched = all.filter { $0.title.lowercased() == calName.lowercased() }
        if matched.isEmpty {
            exitError("Calendar '\(calName)' not found. Use 'cal-tools calendars' to list available calendars.")
        }
        calendars = matched
    }

    let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
    let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    let serialized = events.map { serializeEvent($0) }
    exitSuccess(["events": serialized])
}

func cmdEvent(store: EKEventStore, args: Args) {
    guard let eventId = args.value("id") else {
        exitError("Missing --id parameter.")
    }
    guard let event = store.event(withIdentifier: eventId) else {
        exitError("Event not found with ID: \(eventId)")
    }
    exitSuccess(["event": serializeEvent(event)])
}

func cmdCreate(store: EKEventStore, args: Args) {
    guard let title = args.value("title") else {
        exitError("Missing --title parameter.")
    }
    guard let startStr = args.value("start") else {
        exitError("Missing --start parameter.")
    }
    guard let endStr = args.value("end") else {
        exitError("Missing --end parameter.")
    }
    guard let startDate = parseDate(startStr) else {
        exitError("Invalid --start date: \(startStr)")
    }
    guard let endDate = parseDate(endStr) else {
        exitError("Invalid --end date: \(endStr)")
    }

    let event = EKEvent(eventStore: store)
    event.title = title
    event.startDate = startDate
    event.endDate = endDate

    if let calName = args.value("calendar") {
        let all = store.calendars(for: .event)
        if let matched = all.first(where: { $0.title.lowercased() == calName.lowercased() }) {
            event.calendar = matched
        } else {
            exitError("Calendar '\(calName)' not found.")
        }
    } else {
        event.calendar = store.defaultCalendarForNewEvents
    }

    if let location = args.value("location") {
        event.location = location
    }
    if let notes = args.value("notes") {
        event.notes = notes
    }
    if let allDayStr = args.value("all-day") {
        event.isAllDay = (allDayStr.lowercased() == "true")
    }

    do {
        try store.save(event, span: .thisEvent)
        exitSuccess(["event": serializeEvent(event)])
    } catch {
        exitError("Failed to create event: \(error.localizedDescription)")
    }
}

func cmdUpdate(store: EKEventStore, args: Args) {
    guard let eventId = args.value("id") else {
        exitError("Missing --id parameter.")
    }
    guard let event = store.event(withIdentifier: eventId) else {
        exitError("Event not found with ID: \(eventId)")
    }

    if let title = args.value("title") { event.title = title }
    if let startStr = args.value("start") {
        guard let d = parseDate(startStr) else { exitError("Invalid --start date: \(startStr)") }
        event.startDate = d
    }
    if let endStr = args.value("end") {
        guard let d = parseDate(endStr) else { exitError("Invalid --end date: \(endStr)") }
        event.endDate = d
    }
    if let location = args.value("location") { event.location = location }
    if let notes = args.value("notes") { event.notes = notes }
    if let allDayStr = args.value("all-day") {
        event.isAllDay = (allDayStr.lowercased() == "true")
    }
    if let calName = args.value("calendar") {
        let all = store.calendars(for: .event)
        if let matched = all.first(where: { $0.title.lowercased() == calName.lowercased() }) {
            event.calendar = matched
        } else {
            exitError("Calendar '\(calName)' not found.")
        }
    }

    // For recurring events: default to thisEvent, allow "future" for futureEvents
    var span: EKSpan = .thisEvent
    if let spanStr = args.value("span"), spanStr == "future" {
        span = .futureEvents
    }

    do {
        try store.save(event, span: span)
        exitSuccess(["event": serializeEvent(event)])
    } catch {
        exitError("Failed to update event: \(error.localizedDescription)")
    }
}

func cmdDelete(store: EKEventStore, args: Args) {
    guard let eventId = args.value("id") else {
        exitError("Missing --id parameter.")
    }
    guard let event = store.event(withIdentifier: eventId) else {
        exitError("Event not found with ID: \(eventId)")
    }

    var span: EKSpan = .thisEvent
    if let spanStr = args.value("span"), spanStr == "future" {
        span = .futureEvents
    }

    do {
        try store.remove(event, span: span)
        exitSuccess(["deleted": true, "id": eventId])
    } catch {
        exitError("Failed to delete event: \(error.localizedDescription)")
    }
}

func cmdSearch(store: EKEventStore, args: Args) {
    guard let query = args.value("query") else {
        exitError("Missing --query parameter.")
    }

    let now = Date()
    let fromDate: Date
    let toDate: Date

    if let fromStr = args.value("from"), let d = parseDate(fromStr) {
        fromDate = d
    } else {
        // Default: 90 days ago
        fromDate = Calendar.current.date(byAdding: .day, value: -90, to: now)!
    }

    if let toStr = args.value("to"), let d = parseDate(toStr) {
        toDate = d
    } else {
        // Default: 90 days ahead
        toDate = Calendar.current.date(byAdding: .day, value: 90, to: now)!
    }

    let predicate = store.predicateForEvents(withStart: fromDate, end: toDate, calendars: nil)
    let allEvents = store.events(matching: predicate)
    let lowerQuery = query.lowercased()
    let matched = allEvents.filter { event in
        let title = (event.title ?? "").lowercased()
        let notes = (event.notes ?? "").lowercased()
        let location = (event.location ?? "").lowercased()
        return title.contains(lowerQuery) || notes.contains(lowerQuery) || location.contains(lowerQuery)
    }.sorted { $0.startDate < $1.startDate }

    let serialized = matched.map { serializeEvent($0) }
    exitSuccess(["events": serialized, "query": query, "count": serialized.count])
}

// MARK: - Main

let store = EKEventStore()
let semaphore = DispatchSemaphore(value: 0)
let parsedArgs = Args()

guard let subcommand = parsedArgs.subcommand else {
    exitError("Usage: cal-tools <calendars|events|event|create|update|delete|search> [options]")
}

let requestAccess: (@escaping (Bool, Error?) -> Void) -> Void = { completion in
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents(completion: completion)
    } else {
        store.requestAccess(to: .event, completion: completion)
    }
}

requestAccess { granted, error in
    defer { semaphore.signal() }

    guard granted else {
        let msg = error?.localizedDescription ?? "unknown error"
        exitError("Calendar access denied (\(msg)). Grant permission in System Settings > Privacy & Security > Calendars.")
    }

    switch subcommand {
    case "calendars":
        cmdCalendars(store: store)
    case "events":
        cmdEvents(store: store, args: parsedArgs)
    case "event":
        cmdEvent(store: store, args: parsedArgs)
    case "create":
        cmdCreate(store: store, args: parsedArgs)
    case "update":
        cmdUpdate(store: store, args: parsedArgs)
    case "delete":
        cmdDelete(store: store, args: parsedArgs)
    case "search":
        cmdSearch(store: store, args: parsedArgs)
    default:
        exitError("Unknown command: \(subcommand). Use: calendars, events, event, create, update, delete, search")
    }
}

_ = semaphore.wait(timeout: .distantFuture)
