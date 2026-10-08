import SwiftUI

public struct OpenURLSheetView: View {
    public var onOpen: (URL, [String: String]) -> Void
    public var onCancel: () -> Void

    @State private var urlString: String = ""
    @State private var headerKey: String = "Authorization"
    @State private var headerValue: String = ""
    @State private var customHeaders: [(key: String, value: String)] = []
    @State private var showingHeaderInputs: Bool = false

    public init(
        onOpen: @escaping (URL, [String: String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onOpen = onOpen
        self.onCancel = onCancel
    }

    private var isValidURL: Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased()
        else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Open Network Stream")
                    .font(.headline)
            }

            // Stream URL field
            VStack(alignment: .leading, spacing: 6) {
                Text("Stream or Video URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://example.com/stream.mkv or http://...", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 420)
            }

            // Authentication & Custom Headers Section
            DisclosureGroup(
                isExpanded: $showingHeaderInputs,
                content: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Add custom HTTP request headers for authentication tokens, proxies, or credentials.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // Input row
                        HStack(spacing: 8) {
                            TextField("Header Name", text: $headerKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)

                            TextField("Value / Token", text: $headerValue)
                                .textFieldStyle(.roundedBorder)

                            Button("Add") {
                                let key = headerKey.trimmingCharacters(in: .whitespaces)
                                let val = headerValue.trimmingCharacters(in: .whitespaces)
                                if !key.isEmpty && !val.isEmpty {
                                    customHeaders.append((key, val))
                                    headerValue = ""
                                }
                            }
                            .disabled(
                                headerKey.trimmingCharacters(in: .whitespaces).isEmpty
                                    || headerValue.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        // Presets
                        HStack(spacing: 6) {
                            Text("Presets:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button("Authorization") {
                                headerKey = "Authorization"
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)

                            Button("API Key / Token") {
                                headerKey = "X-Api-Key"
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)

                            Button("User-Agent") {
                                headerKey = "User-Agent"
                                headerValue = "MetalPlayer/1.0"
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                        }

                        // Configured headers list
                        if !customHeaders.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(customHeaders.indices, id: \.self) { idx in
                                    HStack {
                                        Text("\(customHeaders[idx].key): \(customHeaders[idx].value)")
                                            .font(.caption.monospaced())
                                            .lineLimit(1)
                                        Spacer()
                                        Button {
                                            customHeaders.remove(at: idx)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(8)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.top, 6)
                },
                label: {
                    HStack {
                        Text("HTTP Authentication & Headers")
                            .font(.subheadline.weight(.medium))
                        if !customHeaders.isEmpty {
                            Text("(\(customHeaders.count))")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            )

            // Buttons
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Open Stream") {
                    guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        return
                    }
                    var dict: [String: String] = [:]
                    for h in customHeaders {
                        dict[h.key] = h.value
                    }
                    // Auto-include currently typed header if user forgot to click Add
                    let currentKey = headerKey.trimmingCharacters(in: .whitespaces)
                    let currentVal = headerValue.trimmingCharacters(in: .whitespaces)
                    if !currentKey.isEmpty && !currentVal.isEmpty {
                        dict[currentKey] = currentVal
                    }
                    onOpen(url, dict)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValidURL)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}
