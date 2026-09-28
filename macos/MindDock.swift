import AppKit
import SwiftUI
import Foundation

private struct Config: Decodable {
    let apiBaseURL: String
    let apiKey: String

    static func load() throws -> Config {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MindDock/config.json")
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }
}

private struct APIError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct Person: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let company: String?
    let role: String?
    let email: String?
    let linkedinUrl: String?
    let research: String?
}

struct Meeting: Decodable, Identifiable {
    let id: String
    let personId: String
    let title: String?
    let startedAt: String
    let endedAt: String?
    let summary: String?
    let transcript: String?
}

private struct ActionItem: Decodable, Identifiable {
    let id: String
    let text: String
    let owner: String
    let completed: Bool
}

private struct SearchResult: Decodable {
    let people: [Person]
    let meetings: [Meeting]
}

private struct PersonInput: Encodable {
    let name: String
    let company: String?
    let role: String?
    let research: String?
}

struct MeetingInput: Encodable {
    let personId: String
    let title: String?
    let startedAt: String
    let endedAt: String?
    let summary: String?
    let transcript: String
}

private struct ActionInput: Encodable {
    let text: String
    let owner: String
}

private struct EmptyBody: Encodable {}

struct APIClient {
    private let config: Config?
    private let configError: String?

    init() {
        do {
            config = try Config.load()
            configError = nil
        } catch {
            config = nil
            configError = "MindDock is not configured. Run the one-time installer from the project folder."
        }
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, method: "GET", body: Optional<EmptyBody>.none)
    }

    func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        try await request(path, method: "POST", body: body)
    }

    private func request<T: Decodable, Body: Encodable>(_ path: String, method: String, body: Body?) async throws -> T {
        guard let config else { throw APIError(message: configError ?? "Missing configuration") }
        guard let url = URL(string: config.apiBaseURL + path) else { throw APIError(message: "Invalid API URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "No HTTP response") }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw APIError(message: "API error \(http.statusCode): \(detail)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

@MainActor private final class MemoryStore: ObservableObject {
    @Published var people: [Person] = []
    @Published var meetings: [Meeting] = []
    @Published var searchResult: SearchResult?
    @Published var error: String?
    @Published var busy = false
    let api = APIClient()

    func refreshPeople() async {
        do { people = try await api.get("/people") }
        catch { self.error = error.localizedDescription }
    }

    func refreshMeetings(personId: String) async {
        do { meetings = try await api.get("/people/\(personId)/meetings") }
        catch { self.error = error.localizedDescription }
    }

    func search(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { searchResult = nil; return }
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        do { searchResult = try await api.get("/search\(components.string ?? "")") }
        catch { self.error = error.localizedDescription }
    }
}

private struct MeetingSelection: Identifiable { let id: String }
private struct RecordingSelection: Identifiable { let id: String }

@main struct MindDockApp: App {
    var body: some Scene {
        WindowGroup {
            MindDockView()
                .frame(minWidth: 880, minHeight: 600)
        }
        .windowStyle(.automatic)
    }
}

private struct MindDockView: View {
    @StateObject private var store = MemoryStore()
    @State private var personID: String?
    @State private var searchText = ""
    @State private var showNewPerson = false
    @State private var showNewMeeting = false
    @State private var selectedMeeting: MeetingSelection?
    @StateObject private var recorder = MeetingRecorder()
    @State private var recordingSelection: RecordingSelection?
    @State private var recordingTitle = ""
    @State private var recordingLanguage = "en-US"

    private var person: Person? { store.people.first(where: { $0.id == personID }) }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("Search memories", text: $searchText)
                        .onSubmit { Task { await store.search(searchText) } }
                    if !searchText.isEmpty {
                        Button { searchText = ""; store.searchResult = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.top, 10)

                List(selection: $personID) {
                    Section("People") {
                        ForEach(store.people) { person in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.name).fontWeight(.medium)
                                if let company = person.company { Text(company).font(.caption).foregroundStyle(.secondary) }
                            }
                            .tag(person.id)
                        }
                    }
                }
            }
            .navigationTitle("MindDock")
            .toolbar {
                Button { showNewPerson = true } label: { Image(systemName: "person.crop.circle.badge.plus") }
                    .help("Add person")
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250)
        } detail: {
            if let result = store.searchResult, !searchText.isEmpty {
                SearchResultsView(result: result, openPerson: { personID = $0; searchText = ""; store.searchResult = nil }, openMeeting: { selectedMeeting = MeetingSelection(id: $0) })
            } else if let person {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(person.name).font(.largeTitle.bold())
                                Text([person.role, person.company].compactMap { $0 }.joined(separator: " · "))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Record meeting", systemImage: "record.circle") {
                                recordingTitle = ""
                                recordingSelection = RecordingSelection(id: person.id)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Add transcript", systemImage: "plus") { showNewMeeting = true }
                        }
                        if let research = person.research, !research.isEmpty {
                            GroupBox("Research") { Text(research).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                        HStack {
                            Text("Meetings").font(.title2.bold())
                            Spacer()
                            Text("\(store.meetings.count)").foregroundStyle(.secondary)
                        }
                        if store.meetings.isEmpty {
                            ContentUnavailableView("No meetings yet", systemImage: "waveform", description: Text("Record a meeting or add a transcript."))
                        }
                        ForEach(store.meetings) { meeting in
                            Button { selectedMeeting = MeetingSelection(id: meeting.id) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(meeting.title ?? "Untitled meeting").font(.headline)
                                    Text(meeting.startedAt).font(.caption).foregroundStyle(.secondary)
                                    if let summary = meeting.summary { Text(summary).lineLimit(2).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 850, alignment: .leading)
                }
                .navigationTitle(person.name)
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView("Your meeting memory", systemImage: "waveform", description: Text("Choose a person or add someone new."))
                    Button("Add a person", systemImage: "person.crop.circle.badge.plus") { showNewPerson = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await store.refreshPeople() }
        .onChange(of: personID) { _, id in
            store.meetings = []
            if let id { Task { await store.refreshMeetings(personId: id) } }
        }
        .sheet(isPresented: $showNewPerson) {
            NewPersonView(api: store.api) { newPerson in
                store.people.append(newPerson)
                store.people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                personID = newPerson.id
            }
        }
        .sheet(isPresented: $showNewMeeting) {
            if let personID {
                NewMeetingView(api: store.api, personID: personID) { _ in
                    Task { await store.refreshMeetings(personId: personID) }
                }
            }
        }
        .sheet(item: $selectedMeeting) { selection in
            MeetingDetailView(api: store.api, id: selection.id)
        }
        .sheet(item: $recordingSelection) { selection in
            RecordingView(api: store.api, recorder: recorder, personID: selection.id, title: $recordingTitle, language: $recordingLanguage) { _ in
                Task { await store.refreshMeetings(personId: selection.id) }
            }
        }
        .alert("MindDock", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

private struct SearchResultsView: View {
    let result: SearchResult
    let openPerson: (String) -> Void
    let openMeeting: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Search results").font(.largeTitle.bold())
                if result.people.isEmpty && result.meetings.isEmpty {
                    ContentUnavailableView.search
                }
                if !result.people.isEmpty {
                    Text("People").font(.headline)
                    ForEach(result.people) { person in
                        Button(person.name) { openPerson(person.id) }
                    }
                }
                if !result.meetings.isEmpty {
                    Text("Meetings").font(.headline)
                    ForEach(result.meetings) { meeting in
                        Button(meeting.title ?? "Untitled meeting") { openMeeting(meeting.id) }
                            .help(meeting.summary ?? meeting.startedAt)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }
}

private struct NewPersonView: View {
    @Environment(\.dismiss) private var dismiss
    let api: APIClient
    let onCreated: (Person) -> Void
    @State private var name = ""
    @State private var company = ""
    @State private var role = ""
    @State private var research = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New person").font(.title2.bold())
            TextField("Name", text: $name)
            TextField("Company (optional)", text: $company)
            TextField("Role (optional)", text: $role)
            TextField("Research notes (optional)", text: $research, axis: .vertical)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        do {
                            let person: Person = try await api.post("/people", body: PersonInput(name: name, company: company.isEmpty ? nil : company, role: role.isEmpty ? nil : role, research: research.isEmpty ? nil : research))
                            onCreated(person)
                            dismiss()
                        } catch { self.error = error.localizedDescription; saving = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}

private struct NewMeetingView: View {
    @Environment(\.dismiss) private var dismiss
    let api: APIClient
    let personID: String
    let onCreated: (Meeting) -> Void
    @State private var title = ""
    @State private var startedAt = Date()
    @State private var summary = ""
    @State private var transcript = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add transcript").font(.title2.bold())
            TextField("Meeting title (optional)", text: $title)
            DatePicker("Started", selection: $startedAt)
            Text("Summary (optional)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $summary).frame(height: 70).border(.quaternary)
            Text("Transcript").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $transcript).frame(height: 170).border(.quaternary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(saving ? "Saving…" : "Save meeting") {
                    saving = true
                    Task {
                        do {
                            let meeting: Meeting = try await api.post("/meetings", body: MeetingInput(personId: personID, title: title.isEmpty ? nil : title, startedAt: ISO8601DateFormatter().string(from: startedAt), endedAt: nil, summary: summary.isEmpty ? nil : summary, transcript: transcript))
                            onCreated(meeting)
                            dismiss()
                        } catch { self.error = error.localizedDescription; saving = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}

private struct MeetingDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let api: APIClient
    let id: String
    @State private var meeting: Meeting?
    @State private var actions: [ActionItem] = []
    @State private var actionText = ""
    @State private var owner = "me"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(meeting?.title ?? "Meeting").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            if let meeting {
                Text(meeting.startedAt).foregroundStyle(.secondary)
                if let summary = meeting.summary, !summary.isEmpty { GroupBox("Summary") { Text(summary).frame(maxWidth: .infinity, alignment: .leading) } }
                Text("Transcript").font(.headline)
                ScrollView { Text(meeting.transcript ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: .infinity)
                Divider()
                Text("Action items").font(.headline)
                ForEach(actions) { action in
                    Label("\(action.text) · \(action.owner)", systemImage: action.completed ? "checkmark.circle.fill" : "circle")
                }
                HStack {
                    TextField("New action item", text: $actionText)
                    Picker("Owner", selection: $owner) {
                        Text("Me").tag("me")
                        Text("Them").tag("them")
                    }.frame(width: 130)
                    Button("Add") {
                        Task {
                            do {
                                let item: ActionItem = try await api.post("/meetings/\(id)/action-items", body: ActionInput(text: actionText, owner: owner))
                                actions.append(item)
                                actionText = ""
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(actionText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding(24)
        .frame(width: 700, height: 580)
        .task {
            do {
                meeting = try await api.get("/meetings/\(id)")
                actions = try await api.get("/meetings/\(id)/action-items")
            } catch { self.error = error.localizedDescription }
        }
    }
}
