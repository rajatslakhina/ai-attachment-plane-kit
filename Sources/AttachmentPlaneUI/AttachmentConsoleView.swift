#if canImport(SwiftUI)
import SwiftUI
import AttachmentPlane

/// A console that drives the real `AttachmentPlane` against a simulated Files
/// API and shows what each guarantee did: counters, the dedup index and the
/// event log.
public struct AttachmentConsoleView: View {
    @State private var model: AttachmentConsoleModel
    private let autoRun: [ConsoleScenario]

    /// - Parameters:
    ///   - configuration: owned by the host app (limits, TTL, budget).
    ///   - autoRun: scenarios to run once on appear, in order (used for
    ///     screenshot automation via launch arguments).
    public init(configuration: ConsoleConfiguration, autoRun: [ConsoleScenario] = []) {
        // `State(initialValue:)` keeps the first model for the view's lifetime;
        // later re-inits build a throwaway model (about 1 MB of synthetic bytes
        // hashed once). Fine at an app root, which is where this console lives.
        _model = State(initialValue: AttachmentConsoleModel(configuration: configuration))
        self.autoRun = autoRun
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.lastOutcome)
                        .font(.callout)
                        .accessibilityIdentifier("outcome")
                    MetricsGrid(metrics: model.metrics, liveRemoteFiles: model.liveRemoteFiles)
                } header: {
                    Text("What happened")
                }

                Section("Scenarios") {
                    ForEach(ConsoleScenario.allCases) { scenario in
                        Button {
                            Task { await model.run(scenario) }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scenario.title)
                                    Text(scenario.guarantee).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: scenario.symbol)
                            }
                        }
                        .disabled(model.busy)
                    }
                }

                Section {
                    if model.entries.isEmpty {
                        Text("Nothing uploaded yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.entries, id: \.digest) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName(for: entry.digest)).font(.subheadline.weight(.semibold))
                                Text("\(entry.remote?.id ?? "—") · \(entry.owners.count) owner\(entry.owners.count == 1 ? "" : "s") · \(model.expiryText(for: entry))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Dedup index (content → remote file)")
                }

                Section("Event log") {
                    if model.log.isEmpty {
                        Text("Events from the plane appear here.").foregroundStyle(.secondary)
                    }
                    ForEach(model.log) { line in
                        Label(line.text, systemImage: line.symbol)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Attachment Plane")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Text(String(format: "Day %.0f", model.elapsedDays))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottom) {
                if model.busy { ProgressView().padding().background(.thinMaterial, in: Capsule()).padding() }
            }
        }
        .task {
            for scenario in autoRun { await model.run(scenario) }
            await model.refresh()
        }
    }
}

private struct MetricsGrid: View {
    let metrics: PlaneMetrics
    let liveRemoteFiles: Int

    var body: some View {
        let tiles: [(String, String)] = [
            ("Uploads", "\(metrics.uploads)"),
            ("Reused", "\(metrics.reuses)"),
            ("Joined in flight", "\(metrics.joinedInFlight)"),
            ("Retries", "\(metrics.retries)"),
            ("Expiring replaced", "\(metrics.expiringReplaced)"),
            ("Heals", "\(metrics.heals)"),
            ("Refused", "\(metrics.refusals)"),
            ("Collected", "\(metrics.collected)"),
            ("Live remote files", "\(liveRemoteFiles)"),
            ("Not uploaded", AttachmentConsoleModel.bytes(metrics.bytesNotUploaded)),
        ]
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
            ForEach(tiles, id: \.0) { tile in
                VStack(spacing: 2) {
                    Text(tile.1).font(.title3.monospacedDigit().weight(.semibold))
                    Text(tile.0).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .padding(6)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
