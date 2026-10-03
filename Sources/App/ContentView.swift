import SwiftUI
import AVKit
import AppKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var discovery: CameraDiscovery
    @State private var tab = 0
    @State private var showPassword = false

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 250, idealWidth: 270, maxWidth: 310)
            VStack(spacing: 0) {
                HStack {
                    Text(tab == 0 ? "相机素材库" : tab == 1 ? "同步队列" : "连接与真机验证").font(.title2.bold())
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Label(model.connected ? "相机已连接" : "相机未连接", systemImage: model.connected ? "wifi" : "wifi.slash")
                        .font(.callout).foregroundStyle(model.connected ? .green : .secondary)
                }.padding(20)
                Divider()
                if tab == 0 { library } else if tab == 1 { transfers } else { diagnostics }
            }.frame(minWidth: 740, maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("相机素材同步", systemImage: "camera.fill").font(.title3.bold())
            VStack(alignment: .leading, spacing: 10) {
                Text("1 · 连接相机").font(.headline)
                Text(discovery.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(discovery.isScanning ? "停止扫描" : "扫描 Action 5 Pro") {
                    if discovery.isScanning { discovery.stopScan() } else { discovery.startScan() }
                }.disabled(model.busy || model.running)
                ForEach(discovery.devices) { device in
                    Button { model.prepare(device) } label: {
                        HStack { Image(systemName: "camera"); Text(device.name).lineLimit(1); Spacer(); Image(systemName: "chevron.right") }
                    }.disabled(model.busy || model.running)
                }
                if let credentials = model.credentials {
                    Divider()
                    Text("2 · 在系统菜单连接 WiFi").font(.headline)
                    Text(credentials.ssid).font(.callout.monospaced()).textSelection(.enabled)
                    HStack {
                        if showPassword { Text(credentials.password).font(.caption.monospaced()).textSelection(.enabled) }
                        Button(showPassword ? "隐藏密码" : "显示密码") { showPassword.toggle() }.font(.caption)
                        Button("复制密码") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(credentials.password, forType: .string) }.font(.caption)
                    }
                    Text("连接热点期间，Mac 可能暂时无法通过原 WiFi 上网。").font(.caption).foregroundStyle(.secondary)
                    Button(model.connected ? "刷新完整素材库" : "已连接热点，读取素材") { model.connectAndScan() }
                        .buttonStyle(.borderedProminent).disabled(model.busy || model.running)
                    Button("断开相机") { model.disconnect() }
                }
            }
            Divider()
            VStack(spacing: 8) {
                navigation("素材库", icon: "square.grid.2x2", tag: 0, count: model.media.count)
                navigation("同步队列", icon: "arrow.down.circle", tag: 1, count: model.records.filter { $0.state != .complete }.count)
                navigation("连接验证", icon: "checkmark.shield", tag: 2, count: nil)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("保存到 Mac").font(.headline)
                Text(model.destination?.path ?? "尚未选择保存目录").font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                Button("选择保存目录…") { model.chooseDestination() }.disabled(model.running || model.enqueuing)
                Text("按拍摄日期整理 · 保存原片 · 保留相机素材").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(20).background(Color(nsColor: .windowBackgroundColor))
    }
    private func navigation(_ title: String, icon: String, tag: Int, count: Int?) -> some View {
        Button { tab = tag } label: {
            HStack { Label(title, systemImage: icon); Spacer(); if let count { Text("\(count)").foregroundStyle(.secondary) } }
                .padding(9).background(tab == tag ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private var library: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("存储", selection: $model.storageFilter) {
                    Text("全部存储").tag(-1); Text("SD 卡").tag(0); Text("内置存储").tag(1)
                }.frame(width: 145)
                Picker("类型", selection: $model.kindFilter) { Text("全部").tag(0); Text("照片").tag(1); Text("视频").tag(2) }
                    .pickerStyle(.segmented).frame(width: 170)
                TextField("搜索文件名", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 230)
                Spacer()
                Button("全选当前") { model.selection.formUnion(model.filteredMedia.map(\.id)) }
                Button("清空选择") { model.selection = [] }
            }.padding(14)
            HSplitView {
                Group {
                if model.media.isEmpty {
                    ContentUnavailableView(model.busy ? "正在读取相机素材" : "连接相机，浏览素材", systemImage: "camera.on.rectangle",
                                           description: Text(model.busy ? "列表分批显示，完整扫描后即可同步全部新增" : "先完成蓝牙配对，再手动连接相机热点"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220))], spacing: 14) {
                            ForEach(model.filteredMedia) { item in mediaCard(item) }
                        }.padding(16)
                    }
                }
                }.frame(minWidth: 360, idealWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                previewPane.frame(minWidth: 270, idealWidth: 310, maxWidth: 460)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text("\(model.filteredMedia.count) 项 · 已选 \(model.selection.count) 项").font(.callout).foregroundStyle(.secondary)
                if !model.scanComplete, !model.media.isEmpty { Text("列表尚未完整").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("下载所选") { model.enqueue(model.selectedItems); tab = 1 }
                    .disabled(model.selectedItems.isEmpty || !model.connected || model.destination == nil || model.busy || model.enqueuing)
                Button("同步全部新增（\(model.remainingCount)）") { model.enqueue(model.media); tab = 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.scanComplete || !model.connected || model.destination == nil || model.remainingCount == 0 || model.enqueuing)
            }.padding(16)
        }
    }
    private func mediaCard(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)).frame(height: 112)
                if let thumbnail = model.thumbnails[item.version] {
                    Image(nsImage: thumbnail).resizable().scaledToFill().frame(height: 112).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                } else { Image(systemName: item.isVideo ? "video" : "photo").font(.largeTitle).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 112) }
                if item.isVideo { Label(duration(item.duration), systemImage: "play.fill").font(.caption2).padding(5).background(.ultraThinMaterial, in: Capsule()).padding(6) }
            }.contentShape(Rectangle()).onTapGesture { model.preview(item) }
            HStack(alignment: .top) {
                Toggle("选择", isOn: Binding(get: { model.selection.contains(item.id) }, set: {
                    if $0 { model.selection.insert(item.id) } else { model.selection.remove(item.id) }
                })).labelsHidden().toggleStyle(.checkbox)
                Text(item.filename).font(.caption).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 0)
                if model.completedVersions.contains(item.version) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("原片已同步") }
            }
            Text("\(item.dayFolder) · \(size(item.size))").font(.caption2).foregroundStyle(.secondary)
            Text(item.storage.title).font(.caption2).foregroundStyle(.secondary)
            Button("预览") { model.preview(item) }.buttonStyle(.borderless)
        }.padding(9)
            .background(model.previewItem?.id == item.id ? Color.accentColor.opacity(0.08) : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.selection.contains(item.id) ? Color.accentColor : Color.secondary.opacity(0.15)))
            .task(id: item.version + String(model.connected)) { await model.thumbnail(item) }
            .contextMenu {
                Button("预览") { model.preview(item) }
                Button("下载原片") { model.enqueue([item]) }.disabled(!model.connected || model.destination == nil)
            }
    }
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("素材预览").font(.headline)
            if let player = model.player {
                NativeVideoPlayer(player: player).frame(minHeight: 210)
                HStack {
                    Button("播放", systemImage: "play.fill") { player.play() }
                    Button("暂停", systemImage: "pause.fill") { player.pause() }
                    Button("从头播放") { player.seek(to: .zero); player.play() }
                }
            }
            else if let image = model.previewImage { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 400) }
            else { Image(systemName: "play.rectangle").font(.system(size: 44)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 180) }
            Text(model.previewStatus).font(.callout).foregroundStyle(.secondary)
            if let item = model.previewItem {
                Text(item.filename).font(.callout.bold()).textSelection(.enabled)
                LabeledContent("来源", value: item.storage.title)
                LabeledContent("拍摄日期", value: item.dayFolder)
                LabeledContent("原片大小", value: size(item.size))
                if model.previewNeedsOriginal {
                    Button("下载原片并预览") { model.enqueue([item]) }.disabled(!model.connected || model.destination == nil)
                }
                Text(item.path).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            Spacer()
        }.padding(18).background(Color(nsColor: .controlBackgroundColor))
    }
    private var transfers: some View {
        VStack {
            HStack {
                Text(model.running ? "正在同步 · \(size(Int64(model.speed)))/秒" : "等待同步").foregroundStyle(.secondary)
                Spacer()
                Button("暂停全部") { model.pauseQueue() }.disabled(!model.running)
                Button("恢复 / 重试") { model.resumeQueue() }.disabled(model.running || !model.connected || model.busy)
            }.padding(16)
            if model.records.isEmpty { ContentUnavailableView("还没有同步任务", systemImage: "arrow.down.circle", description: Text("在素材库选择文件，或同步全部新增素材")) }
            else {
                List(model.records.reversed()) { record in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Image(systemName: record.state == .complete ? "checkmark.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(record.state == .complete ? .green : .secondary)
                            Text(record.item.filename).fontWeight(.medium)
                            Spacer(); Text(state(record.state)).foregroundStyle(record.state == .failed ? .red : .secondary)
                            if LocalFiles.validCompleted(record) {
                                Button("预览") { tab = 0; model.preview(record.item) }
                                Button("Finder") { model.reveal(record) }
                                Button("对比 USB 原片…") { model.verify(record) }
                            }
                        }
                        if record.state != .complete { ProgressView(value: Double(record.bytes), total: Double(max(1, record.total))) }
                        Text("\(record.item.storage.title) · \(size(record.bytes)) / \(size(record.total))").font(.caption).foregroundStyle(.secondary)
                        if let error = record.error { Text(error).font(.caption).foregroundStyle(.red) }
                        Text(record.destination).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                    }.padding(.vertical, 6)
                }
            }
        }
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("真机验证状态") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("相机", value: model.camera?.name ?? "未选择")
                    LabeledContent("固件", value: model.firmware)
                    LabeledContent("蓝牙配对", value: model.credentials == nil ? "未完成" : "已完成")
                    LabeledContent("完整扫描", value: model.scanComplete ? "已完成" : "未完成")
                    ForEach(CameraStorage.allCases) { storage in LabeledContent(storage.title, value: "\(model.media.filter { $0.storage == storage }.count) 项") }
                    Text("首轮请分别测试照片、视频代理和大视频下载；断开热点后恢复，并使用队列中的“对比 USB 原片”检查 SHA-256。").font(.callout).foregroundStyle(.secondary)
                }.padding(10)
            }
            HStack {
                Text("连接诊断").font(.headline); Spacer()
                Button("复制诊断信息") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("固件：\(model.firmware)\n完整扫描：\(model.scanComplete)\n" + model.logs.joined(separator: "\n"), forType: .string)
                }
            }
            ScrollView {
                Text(model.logs.isEmpty ? "尚无连接记录。请先扫描并配对相机。" : model.logs.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(12)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }.padding(22)
    }
    private func size(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func duration(_ seconds: Int) -> String { "\(seconds / 60):\(String(format: "%02d", seconds % 60))" }
    private func state(_ value: TransferState) -> String {
        switch value { case .queued: return "等待中"; case .downloading: return "下载中"; case .finalizing: return "校验并提交"; case .paused: return "已暂停"; case .failed: return "失败，可重试"; case .complete: return "已完成" }
    }
}

// 使用 AppKit 播放器，避开当前系统 SwiftUI VideoPlayer 初始化时的运行时崩溃。
private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
