import Foundation
import EventKit
import CoreImage

// MARK: - JSON Output Helpers

func nullable(_ value: Any?) -> Any {
    return value ?? NSNull()
}

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

// MARK: - Date Formatting

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

let utcFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

let humanDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .long
    f.timeStyle = .short
    return f
}()

func parseDate(_ string: String) -> Date? {
    if let d = isoFormatter.date(from: string) { return d }
    if string.count == 19 {
        let withZ = string + TimeZone.current.iso8601Offset()
        if let d = isoFormatter.date(from: withZ) { return d }
    }
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

func formatDate(_ date: Date?) -> Any {
    guard let date = date else { return NSNull() }
    return outputFormatter.string(from: date)
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

// MARK: - Color Helpers

func hexColor(_ cgColor: CGColor?) -> Any {
    guard let color = cgColor else { return NSNull() }
    let ciColor = CIColor(cgColor: color)
    let r = Int(ciColor.red * 255)
    let g = Int(ciColor.green * 255)
    let b = Int(ciColor.blue * 255)
    return String(format: "#%02X%02X%02X", r, g, b)
}

// MARK: - Virtual Conference Helpers

func isConferenceUrl(_ string: String) -> Bool {
    let patterns = [
        "zoom.us/j/", "zoom.us/my/",
        "meet.google.com/",
        "teams.microsoft.com/l/meetup-join",
        "facetime.apple.com/",
        "webex.com/meet/", "webex.com/join/",
        "gotomeeting.com/join/",
        "chime.aws/"
    ]
    let lower = string.lowercased()
    return patterns.contains { lower.contains($0) }
}

func detectProvider(_ url: String) -> String {
    let lower = url.lowercased()
    if lower.contains("zoom.us") { return "Zoom" }
    if lower.contains("meet.google.com") { return "Google Meet" }
    if lower.contains("teams.microsoft.com") { return "Microsoft Teams" }
    if lower.contains("facetime.apple.com") { return "FaceTime" }
    if lower.contains("webex.com") { return "Webex" }
    if lower.contains("gotomeeting.com") { return "GoToMeeting" }
    if lower.contains("chime.aws") { return "Amazon Chime" }
    return "Virtual Meeting"
}

func extractConferenceDetails(_ notes: String) -> String? {
    let keywords = ["meeting id", "passcode", "password", "dial", "pin", "phone", "call-in", "join by"]
    let lines = notes.components(separatedBy: .newlines)
    let relevant = lines.filter { line in
        let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
        return !lower.isEmpty && keywords.contains { lower.contains($0) }
    }
    return relevant.isEmpty ? nil : relevant.joined(separator: "\n")
}

func buildVirtualConference(_ event: EKEvent) -> Any {
    var conferenceUrl: String? = nil
    var conferenceName: String? = nil

    if let url = event.url?.absoluteString, isConferenceUrl(url) {
        conferenceUrl = url
        conferenceName = detectProvider(url)
    }

    if conferenceUrl == nil, let loc = event.location, isConferenceUrl(loc) {
        conferenceUrl = loc
        conferenceName = detectProvider(loc)
    }

    guard let url = conferenceUrl else { return NSNull() }

    var dict: [String: Any] = [
        "url": url,
        "name": conferenceName ?? "Virtual Meeting",
        "details": NSNull()
    ]

    if let notes = event.notes, let details = extractConferenceDetails(notes) {
        dict["details"] = details
    }

    return dict
}

// MARK: - Participant Helpers

func mapParticipantStatus(_ status: EKParticipantStatus) -> String {
    switch status {
    case .unknown:    return "unknown"
    case .pending:    return "pending"
    case .accepted:   return "accepted"
    case .declined:   return "declined"
    case .tentative:  return "tentative"
    case .delegated:  return "delegated"
    case .completed:  return "completed"
    case .inProcess:  return "inProcess"
    @unknown default: return "unknown"
    }
}

func mapParticipantRole(_ role: EKParticipantRole) -> String {
    switch role {
    case .unknown:        return "unknown"
    case .required:       return "required"
    case .optional:       return "optional"
    case .chair:          return "chair"
    case .nonParticipant: return "nonParticipant"
    @unknown default:     return "unknown"
    }
}

func mapParticipantType(_ type: EKParticipantType) -> String {
    switch type {
    case .unknown:  return "unknown"
    case .person:   return "person"
    case .room:     return "room"
    case .resource: return "resource"
    case .group:    return "group"
    @unknown default: return "unknown"
    }
}

func serializeParticipants(_ event: EKEvent) -> [[String: Any]] {
    guard let attendees = event.attendees else { return [] }
    return attendees.map { attendee in
        [
            "name": nullable(attendee.name),
            "email": attendee.url.absoluteString
                .replacingOccurrences(of: "mailto:", with: ""),
            "status": mapParticipantStatus(attendee.participantStatus),
            "role": mapParticipantRole(attendee.participantRole),
            "type": mapParticipantType(attendee.participantType),
            "isCurrentUser": attendee.isCurrentUser
        ] as [String: Any]
    }
}

func serializeOrganizer(_ event: EKEvent) -> Any {
    guard let organizer = event.organizer else { return NSNull() }
    return [
        "name": nullable(organizer.name),
        "email": organizer.url.absoluteString
            .replacingOccurrences(of: "mailto:", with: ""),
        "isCurrentUser": organizer.isCurrentUser
    ] as [String: Any]
}

// MARK: - Alarm Helpers

func humanReadableOffset(_ seconds: TimeInterval) -> String {
    let absSeconds = abs(Int(seconds))
    let direction = seconds < 0 ? "before" : "after"

    if absSeconds == 0 { return "At time of event" }

    let days = absSeconds / 86400
    let hours = (absSeconds % 86400) / 3600
    let minutes = (absSeconds % 3600) / 60

    var parts: [String] = []
    if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
    if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
    if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }

    if parts.isEmpty { parts.append("\(absSeconds) second\(absSeconds == 1 ? "" : "s")") }

    return "\(parts.joined(separator: ", ")) \(direction)"
}

func serializeAlarms(_ event: EKEvent) -> [[String: Any]] {
    guard let alarms = event.alarms else { return [] }
    var result: [[String: Any]] = []

    for alarm in alarms {
        var dict: [String: Any] = [:]

        // Location-based alarm
        if let loc = alarm.structuredLocation, loc.title != nil {
            dict["type"] = "location"
            dict["location"] = loc.title ?? "Unknown"
            dict["trigger"] = alarm.proximity == .enter ? "arrive" : "depart"
            dict["triggerHuman"] = alarm.proximity == .enter
                ? "When arriving at \(loc.title ?? "location")"
                : "When leaving \(loc.title ?? "location")"
        } else if let absoluteDate = alarm.absoluteDate {
            dict["type"] = "absolute"
            dict["trigger"] = outputFormatter.string(from: absoluteDate)
            dict["triggerHuman"] = humanDateFormatter.string(from: absoluteDate)
        } else {
            let offset = alarm.relativeOffset
            dict["type"] = "relative"
            dict["trigger"] = Int(offset)
            dict["triggerHuman"] = humanReadableOffset(offset)
        }

        result.append(dict)
    }

    return result
}

// MARK: - Recurrence Helpers

func mapFrequency(_ freq: EKRecurrenceFrequency) -> String {
    switch freq {
    case .daily:   return "daily"
    case .weekly:  return "weekly"
    case .monthly: return "monthly"
    case .yearly:  return "yearly"
    @unknown default: return "unknown"
    }
}

func mapDayOfWeek(_ day: EKWeekday) -> String {
    switch day {
    case .sunday:    return "sunday"
    case .monday:    return "monday"
    case .tuesday:   return "tuesday"
    case .wednesday: return "wednesday"
    case .thursday:  return "thursday"
    case .friday:    return "friday"
    case .saturday:  return "saturday"
    @unknown default: return "unknown"
    }
}

let rruleDayMap: [EKWeekday: String] = [
    .sunday: "SU", .monday: "MO", .tuesday: "TU",
    .wednesday: "WE", .thursday: "TH", .friday: "FR", .saturday: "SA"
]

func buildRRuleString(_ rule: EKRecurrenceRule) -> String {
    var parts: [String] = []

    let freq: String
    switch rule.frequency {
    case .daily:   freq = "DAILY"
    case .weekly:  freq = "WEEKLY"
    case .monthly: freq = "MONTHLY"
    case .yearly:  freq = "YEARLY"
    @unknown default: freq = "DAILY"
    }
    parts.append("FREQ=\(freq)")

    if rule.interval > 1 {
        parts.append("INTERVAL=\(rule.interval)")
    }

    if let days = rule.daysOfTheWeek {
        let dayStrings = days.map { day -> String in
            let abbr = rruleDayMap[day.dayOfTheWeek] ?? "MO"
            if day.weekNumber != 0 {
                return "\(day.weekNumber)\(abbr)"
            }
            return abbr
        }
        parts.append("BYDAY=\(dayStrings.joined(separator: ","))")
    }

    if let daysOfMonth = rule.daysOfTheMonth {
        parts.append("BYMONTHDAY=\(daysOfMonth.map { "\($0)" }.joined(separator: ","))")
    }

    if let months = rule.monthsOfTheYear {
        parts.append("BYMONTH=\(months.map { "\($0)" }.joined(separator: ","))")
    }

    if let weeks = rule.weeksOfTheYear {
        parts.append("BYWEEKNO=\(weeks.map { "\($0)" }.joined(separator: ","))")
    }

    if let positions = rule.setPositions {
        parts.append("BYSETPOS=\(positions.map { "\($0)" }.joined(separator: ","))")
    }

    if let end = rule.recurrenceEnd {
        if let endDate = end.endDate {
            parts.append("UNTIL=\(utcFormatter.string(from: endDate))")
        } else {
            parts.append("COUNT=\(end.occurrenceCount)")
        }
    }

    return parts.joined(separator: ";")
}

func buildHumanRecurrence(_ rule: EKRecurrenceRule) -> String {
    var result = ""

    let interval = rule.interval
    switch rule.frequency {
    case .daily:
        result = interval == 1 ? "Every day" : "Every \(interval) days"
    case .weekly:
        result = interval == 1 ? "Every week" : "Every \(interval) weeks"
    case .monthly:
        result = interval == 1 ? "Every month" : "Every \(interval) months"
    case .yearly:
        result = interval == 1 ? "Every year" : "Every \(interval) years"
    @unknown default:
        result = "Repeating"
    }

    if let days = rule.daysOfTheWeek {
        let dayNames = days.map { day -> String in
            let name = mapDayOfWeek(day.dayOfTheWeek).prefix(3).capitalized
            if day.weekNumber != 0 {
                let ordinal: String
                switch day.weekNumber {
                case 1: ordinal = "1st"
                case 2: ordinal = "2nd"
                case 3: ordinal = "3rd"
                case -1: ordinal = "last"
                default: ordinal = "\(day.weekNumber)th"
                }
                return "\(ordinal) \(name)"
            }
            return name
        }
        result += " on \(dayNames.joined(separator: ", "))"
    }

    if let daysOfMonth = rule.daysOfTheMonth, !daysOfMonth.isEmpty {
        let dayStrs = daysOfMonth.map { "\($0)" }
        result += " on day \(dayStrs.joined(separator: ", "))"
    }

    if let months = rule.monthsOfTheYear, !months.isEmpty {
        let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let names = months.compactMap { m -> String? in
            let idx = m.intValue - 1
            guard idx >= 0 && idx < 12 else { return nil }
            return monthNames[idx]
        }
        result += " in \(names.joined(separator: ", "))"
    }

    if let end = rule.recurrenceEnd {
        if let endDate = end.endDate {
            let df = DateFormatter()
            df.dateStyle = .long
            df.timeStyle = .none
            result += " until \(df.string(from: endDate))"
        } else {
            result += " for \(end.occurrenceCount) occurrences"
        }
    }

    return result
}

func serializeRecurrence(_ event: EKEvent) -> Any {
    guard let rules = event.recurrenceRules, let rule = rules.first else { return NSNull() }

    var dict: [String: Any] = [
        "frequency": mapFrequency(rule.frequency),
        "interval": rule.interval
    ]

    if let days = rule.daysOfTheWeek {
        dict["daysOfWeek"] = days.map { day in
            [
                "dayOfWeek": mapDayOfWeek(day.dayOfTheWeek),
                "weekNumber": day.weekNumber
            ] as [String: Any]
        }
    } else {
        dict["daysOfWeek"] = NSNull()
    }

    if let daysOfMonth = rule.daysOfTheMonth {
        dict["daysOfMonth"] = daysOfMonth.map { $0.intValue }
    } else {
        dict["daysOfMonth"] = NSNull()
    }

    if let months = rule.monthsOfTheYear {
        dict["monthsOfYear"] = months.map { $0.intValue }
    } else {
        dict["monthsOfYear"] = NSNull()
    }

    if let weeks = rule.weeksOfTheYear {
        dict["weeksOfYear"] = weeks.map { $0.intValue }
    } else {
        dict["weeksOfYear"] = NSNull()
    }

    if let positions = rule.setPositions {
        dict["setPositions"] = positions.map { $0.intValue }
    } else {
        dict["setPositions"] = NSNull()
    }

    if let end = rule.recurrenceEnd {
        if let endDate = end.endDate {
            dict["end"] = [
                "type": "date",
                "date": dateOnlyFormatter.string(from: endDate),
                "count": NSNull()
            ] as [String: Any]
        } else {
            dict["end"] = [
                "type": "count",
                "date": NSNull(),
                "count": end.occurrenceCount
            ] as [String: Any]
        }
    } else {
        dict["end"] = NSNull()
    }

    dict["rruleString"] = buildRRuleString(rule)
    dict["human"] = buildHumanRecurrence(rule)

    return dict
}

// MARK: - Location Helpers

func serializeLocation(_ event: EKEvent) -> Any {
    let structLoc = event.structuredLocation
    let plainLoc = event.location

    if structLoc == nil && (plainLoc == nil || plainLoc?.isEmpty == true) {
        return NSNull()
    }

    var dict: [String: Any] = [
        "name": nullable(structLoc?.title ?? plainLoc),
        "latitude": NSNull(),
        "longitude": NSNull(),
        "radius": NSNull()
    ]

    if let geo = structLoc?.geoLocation?.coordinate {
        dict["latitude"] = geo.latitude
        dict["longitude"] = geo.longitude
    }

    if let radius = structLoc?.radius, radius > 0 {
        dict["radius"] = radius
    }

    return dict
}

// MARK: - Event Status & Availability

func mapEventStatus(_ status: EKEventStatus) -> String {
    switch status {
    case .none:      return "none"
    case .confirmed: return "confirmed"
    case .tentative: return "tentative"
    case .canceled:  return "canceled"
    @unknown default: return "unknown"
    }
}

func mapAvailability(_ availability: EKEventAvailability) -> Any {
    switch availability {
    case .notSupported: return NSNull()
    case .busy:         return "busy"
    case .free:         return "free"
    case .tentative:    return "tentative"
    case .unavailable:  return "unavailable"
    @unknown default:   return "unknown"
    }
}

// MARK: - Event Serialization

enum DetailLevel: String {
    case summary
    case full
}

func serializeEvent(_ event: EKEvent, detail: DetailLevel = .full) -> [String: Any] {
    if detail == .summary {
        var dict: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "(No Title)",
            "start": outputFormatter.string(from: event.startDate),
            "end": outputFormatter.string(from: event.endDate),
            "allDay": event.isAllDay,
            "status": mapEventStatus(event.status),
            "calendar": event.calendar?.title ?? ""
        ]
        if let loc = event.structuredLocation?.title ?? event.location, !loc.isEmpty {
            dict["location"] = loc
        } else {
            dict["location"] = NSNull()
        }
        return dict
    }

    // Full detail
    var dict: [String: Any] = [
        "id": event.eventIdentifier ?? "",
        "title": event.title ?? "(No Title)",
        "start": outputFormatter.string(from: event.startDate),
        "end": outputFormatter.string(from: event.endDate),
        "allDay": event.isAllDay,
        "status": mapEventStatus(event.status)
    ]

    // Calendar as nested object
    if let cal = event.calendar {
        dict["calendar"] = [
            "id": cal.calendarIdentifier,
            "title": cal.title,
            "color": hexColor(cal.cgColor)
        ] as [String: Any]
    } else {
        dict["calendar"] = NSNull()
    }

    dict["location"] = serializeLocation(event)
    dict["url"] = nullable(event.url?.absoluteString)
    dict["notes"] = nullable(event.notes)
    dict["availability"] = mapAvailability(event.availability)

    // Travel time — no clean public API, documented as best-effort
    dict["travelTime"] = NSNull()

    dict["virtualConference"] = buildVirtualConference(event)
    dict["participants"] = serializeParticipants(event)
    dict["organizer"] = serializeOrganizer(event)
    dict["alarms"] = serializeAlarms(event)
    dict["recurrence"] = serializeRecurrence(event)
    dict["isDetached"] = event.isDetached
    dict["occurrenceDate"] = outputFormatter.string(from: event.occurrenceDate)
    dict["createdDate"] = formatDate(event.creationDate)
    dict["lastModifiedDate"] = formatDate(event.lastModifiedDate)

    return dict
}

// MARK: - Calendar Serialization

func mapCalendarType(_ type: EKCalendarType) -> String {
    switch type {
    case .local:        return "local"
    case .calDAV:       return "calDAV"
    case .exchange:     return "exchange"
    case .subscription: return "subscription"
    case .birthday:     return "birthday"
    @unknown default:   return "unknown"
    }
}

func mapSourceType(_ type: EKSourceType?) -> String {
    guard let type = type else { return "unknown" }
    switch type {
    case .local:       return "local"
    case .exchange:    return "exchange"
    case .calDAV:      return "calDAV"
    case .mobileMe:    return "mobileMe"
    case .subscribed:  return "subscribed"
    case .birthdays:   return "birthdays"
    @unknown default:  return "unknown"
    }
}

func serializeCalendar(_ cal: EKCalendar) -> [String: Any] {
    return [
        "id": cal.calendarIdentifier,
        "title": cal.title,
        "color": hexColor(cal.cgColor),
        "type": mapCalendarType(cal.type),
        "allowsModify": cal.allowsContentModifications,
        "subscribed": cal.type == .subscription,
        "source": [
            "id": nullable(cal.source?.sourceIdentifier),
            "title": nullable(cal.source?.title),
            "type": mapSourceType(cal.source?.sourceType)
        ] as [String: Any]
    ]
}

// MARK: - Argument Parsing

class Args {
    let args: [String]

    init() {
        self.args = Array(CommandLine.arguments.dropFirst())
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

    var detailLevel: DetailLevel {
        if let val = value("detail"), val == "summary" {
            return .summary
        }
        return .full
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

    let detail = args.detailLevel
    let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
    let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    let serialized = events.map { serializeEvent($0, detail: detail) }
    exitSuccess(["events": serialized])
}

func cmdEvent(store: EKEventStore, args: Args) {
    guard let eventId = args.value("id") else {
        exitError("Missing --id parameter.")
    }
    guard let event = store.event(withIdentifier: eventId) else {
        exitError("Event not found with ID: \(eventId)")
    }
    // Single event lookup always returns full detail
    exitSuccess(["event": serializeEvent(event, detail: .full)])
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
        fromDate = Calendar.current.date(byAdding: .day, value: -90, to: now)!
    }

    if let toStr = args.value("to"), let d = parseDate(toStr) {
        toDate = d
    } else {
        toDate = Calendar.current.date(byAdding: .day, value: 90, to: now)!
    }

    let detail = args.detailLevel
    let predicate = store.predicateForEvents(withStart: fromDate, end: toDate, calendars: nil)
    let allEvents = store.events(matching: predicate)
    let lowerQuery = query.lowercased()
    let matched = allEvents.filter { event in
        let title = (event.title ?? "").lowercased()
        let notes = (event.notes ?? "").lowercased()
        let location = (event.location ?? "").lowercased()
        return title.contains(lowerQuery) || notes.contains(lowerQuery) || location.contains(lowerQuery)
    }.sorted { $0.startDate < $1.startDate }

    let serialized = matched.map { serializeEvent($0, detail: detail) }
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
