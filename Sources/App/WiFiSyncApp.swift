import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动时直接读取随应用打包的图标，避免 Dock 沿用旧版本的默认图标。
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WiFiSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("相机素材同步") {
            ContentView(model: model, discovery: model.discovery)
                .frame(minWidth: 1040, minHeight: 720)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("相机") {
                Button("扫描 Action 5 Pro") { model.discovery.startScan() }.disabled(model.busy || model.running)
                Button("连接并刷新素材") { model.connectAndScan() }.disabled(model.credentials == nil || model.busy || model.running)
                Button("断开连接") { model.disconnect() }
            }
        }
    }
}
