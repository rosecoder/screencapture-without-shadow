import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct WindowInfo: Identifiable {
    let id = UUID()
    var windowName: String
    var appName: String
    let windowNumber: Int
    var lastActiveTime: Date

    // Window order level - lower numbers are older windows
    var orderingValue: Int = 0
}

class WindowManager: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var lastCapturedImagePath: String?
    @Published var isCapturing = false

    private var orderCounter = 0
    private var windowTracker: [Int: WindowInfo] = [:]
    private var timer: Timer?

    init() {
        // Setup a timer to periodically update window list
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshWindows()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func captureWindow(_ window: WindowInfo) {
        isCapturing = true

        // Create a formatted date string for the filename
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateString = dateFormatter.string(from: Date())

        // Get path to user's desktop
        let fileManager = FileManager.default
        let desktopURL = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let windowTitle = window.windowName.isEmpty ? window.appName : window.windowName
        let sanitizedWindowTitle = windowTitle.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileName = "\(sanitizedWindowTitle)_\(dateString).png"
        let fileURL = desktopURL.appendingPathComponent(fileName)
        let filePath = fileURL.path

        // Create and run the screencapture command
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        task.arguments = ["-o", "-l", String(window.windowNumber), filePath]

        task.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.isCapturing = false
                if process.terminationStatus == 0 {
                    self?.lastCapturedImagePath = filePath
                }
            }
        }

        do {
            try task.run()
        } catch {
            print("Failed to capture screenshot: \(error.localizedDescription)")
            isCapturing = false
        }
    }

    func refreshWindows() {
        var newWindows: [WindowInfo] = []
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostAppName = frontmostApp?.localizedName ?? ""

        // Remember the currently frontmost window number
        var frontWindowNumber: Int?
        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[CFString: Any]]
        {
            for windowInfo in windowList {
                if let owner = windowInfo[kCGWindowOwnerName] as? String,
                    owner == frontmostAppName,
                    let layer = windowInfo[kCGWindowLayer] as? Int, layer == 0,
                    let windowNumber = windowInfo[kCGWindowNumber] as? Int
                {
                    frontWindowNumber = windowNumber
                    break
                }
            }
        }

        // Get all windows from all apps
        if let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]]
        {
            for windowInfo in windowInfoList {
                let windowNumber = windowInfo[kCGWindowNumber] as? Int ?? 0
                let ownerName = windowInfo[kCGWindowOwnerName] as? String ?? "Unknown"
                let windowName = windowInfo[kCGWindowName] as? String ?? "Unnamed Window"
                let windowLayer = windowInfo[kCGWindowLayer] as? Int ?? 0

                // Filter out some system windows
                if windowLayer == 0, !ownerName.isEmpty {
                    // Update ordering - frontmost window gets highest order,
                    // previously tracked windows keep their order, new windows get incrementing values
                    let now = Date()
                    let isCurrentlyActive = windowNumber == frontWindowNumber

                    if let existingWindow = windowTracker[windowNumber] {
                        var updatedWindow = existingWindow
                        updatedWindow.windowName = windowName
                        updatedWindow.appName = ownerName

                        if isCurrentlyActive {
                            updatedWindow.orderingValue = orderCounter + 1000  // Give it a high priority
                            updatedWindow.lastActiveTime = now
                            orderCounter += 1
                        }

                        newWindows.append(updatedWindow)
                        windowTracker[windowNumber] = updatedWindow
                    } else {
                        // New window we haven't seen before
                        var ordering = orderCounter
                        if isCurrentlyActive {
                            ordering += 1000
                            orderCounter += 1
                        } else {
                            orderCounter += 1
                        }

                        let windowInfo = WindowInfo(
                            windowName: windowName,
                            appName: ownerName,
                            windowNumber: windowNumber,
                            lastActiveTime: isCurrentlyActive ? now : now.addingTimeInterval(-10),
                            orderingValue: ordering
                        )
                        newWindows.append(windowInfo)
                        windowTracker[windowNumber] = windowInfo
                    }
                }
            }
        }

        // Sort windows by ordering value (most recently active first)
        windows = newWindows.sorted(by: { $0.orderingValue > $1.orderingValue })
    }
}

struct ContentView: View {
    @StateObject private var windowManager = WindowManager()
    @State private var showingCaptureAlert = false
    @State private var lastCapturedWindow: WindowInfo?

    var body: some View {
        VStack {
            Text("Running Windows")
                .font(.title)
                .padding()

            if windowManager.windows.isEmpty {
                VStack {
                    Text("No windows found or accessibility permissions needed")
                        .padding()
                    Button("Refresh Windows") {
                        windowManager.refreshWindows()
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Note: This app requires accessibility permissions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                }
            } else {
                List {
                    ForEach(windowManager.windows) { window in
                        Button(action: {
                            lastCapturedWindow = window
                            windowManager.captureWindow(window)
                            showingCaptureAlert = true
                        }) {
                            VStack(alignment: .leading) {
                                Text(
                                    window.windowName.isEmpty ? "Unnamed Window" : window.windowName
                                )
                                .font(.headline)
                                .foregroundColor(.primary)
                                HStack {
                                    Text(window.appName)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text(window.lastActiveTime, style: .relative)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .refreshable {
                    windowManager.refreshWindows()
                }

                HStack {
                    Spacer()
                    Button("Refresh") {
                        windowManager.refreshWindows()
                    }
                    .padding(.bottom)
                }
            }

            if windowManager.isCapturing {
                HStack {
                    ProgressView()
                        .padding(.trailing, 5)
                    Text("Capturing window...")
                }
                .padding()
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            // Check for accessibility permissions
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            let accessibilityEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
            if accessibilityEnabled {
                windowManager.refreshWindows()
            }
        }
        .alert("Window Captured", isPresented: $showingCaptureAlert) {
            Button("OK", role: .cancel) {}
            if let path = windowManager.lastCapturedImagePath {
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            }
        } message: {
            if let window = lastCapturedWindow {
                Text(
                    "Screenshot of \"\(window.windowName.isEmpty ? "Unnamed Window" : window.windowName)\" saved to Desktop."
                )
            } else {
                Text("Screenshot saved to Desktop.")
            }
        }
    }
}

#Preview {
    ContentView()
}
