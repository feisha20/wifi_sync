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
            sidebar.frame(minWidth: 230, idealWidth: 250, maxWidth: 280)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tab == 0 ? "素材库" : tab == 1 ? "同步队列" : "连接验证").font(.title2.bold())
                        Text(tab == 0 ? "浏览照片与视频，将原片保存到 Mac" : tab == 1 ? "查看传输进度与已保存的原片" : "查看相机连接状态与诊断记录")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Label(model.connected ? "相机已连接" : "离线", systemImage: model.connected ? "wifi" : "wifi.slash")
                        .font(.caption.weight(.medium)).foregroundStyle(model.connected ? .green : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(model.connected ? Color.green.opacity(0.08) : Color.secondary.opacity(0.08), in: Capsule())
                }.padding(.horizontal, 22).padding(.vertical, 16)
                Divider()
                if tab == 0 { library } else if tab == 1 { transfers } else { diagnostics }
            }.frame(minWidth: 740, maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("相机素材同步", systemImage: "camera.fill").font(.headline).padding(.top, 4)
            VStack(spacing: 4) {
                navigation("素材库", icon: "square.grid.2x2", tag: 0, count: model.media.count)
                navigation("同步队列", icon: "arrow.down.circle", tag: 1, count: model.records.filter { $0.state != .complete }.count)
                navigation("连接验证", icon: "checkmark.shield", tag: 2, count: nil)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("相机连接", systemImage: "camera").font(.subheadline.weight(.semibold))
                    Text(discovery.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(discovery.isScanning ? "停止扫描" : "扫描 Action 5 Pro", systemImage: "dot.radiowaves.left.and.right") {
                        if discovery.isScanning { discovery.stopScan() } else { discovery.startScan() }
                    }.disabled(model.busy || model.running)
                    ForEach(discovery.devices) { device in
                        Button { model.prepare(device) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "camera")
                                Text(device.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption2)
                            }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            .disabled(model.busy || model.running)
                    }
                    if let credentials = model.credentials {
                        Divider()
                        Label("连接相机 WiFi", systemImage: "wifi").font(.subheadline.weight(.semibold))
                        Text(credentials.ssid).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                        Text("在系统 WiFi 菜单加入此热点，再读取素材。").font(.caption).foregroundStyle(.secondary)
                        if showPassword { Text(credentials.password).font(.caption.monospaced()).textSelection(.enabled) }
                        HStack(spacing: 8) {
                            Button(showPassword ? "隐藏密码" : "显示密码") { showPassword.toggle() }
                            Button("复制密码") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(credentials.password, forType: .string) }
                        }.controlSize(.small)
                        Button(model.connected ? "刷新素材库" : "已连接热点，读取素材") { model.connectAndScan() }
                            .buttonStyle(.borderedProminent).disabled(model.busy || model.running)
                        Button("断开相机") { model.disconnect() }.controlSize(.small)
                        Text("连接期间，Mac 可能暂时无法通过原 WiFi 上网。").font(.caption2).foregroundStyle(.tertiary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("保存到 Mac", systemImage: "folder").font(.subheadline.weight(.semibold))
                Text(model.destination?.path ?? "尚未选择保存目录").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).help(model.destination?.path ?? "请选择保存目录")
                Button("选择保存目录…") { model.chooseDestination() }.controlSize(.small).disabled(model.running || model.enqueuing)
                Text("按拍摄日期整理 · 保留相机原片").font(.caption2).foregroundStyle(.tertiary)
            }
        }.padding(16).background(Color(nsColor: .windowBackgroundColor))
    }
    private func navigation(_ title: String, icon: String, tag: Int, count: Int?) -> some View {
        Button { tab = tag } label: {
            HStack { Label(title, systemImage: icon); Spacer(); if let count { Text("\(count)").foregroundStyle(.secondary) } }
                .padding(9).background(tab == tag ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private var library: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("存储", selection: $model.storageFilter) {
                    Text("全部存储").tag(-1); Text("SD 卡").tag(0); Text("内置存储").tag(1)
                }.labelsHidden().frame(width: 125).help("筛选存储来源")
                Picker("类型", selection: $model.kindFilter) { Text("全部").tag(0); Text("照片").tag(1); Text("视频").tag(2) }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 165)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索文件名", text: $model.search).textFieldStyle(.plain)
                }.padding(7).frame(minWidth: 110, maxWidth: 240)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                Spacer(minLength: 0)
                Button("全选") { model.selection.formUnion(model.filteredMedia.map(\.id)) }.disabled(model.filteredMedia.isEmpty)
                Button("清空") { model.selection = [] }.disabled(model.selection.isEmpty)
            }.controlSize(.small).padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            HSplitView {
                Group {
                    if model.media.isEmpty {
                        ContentUnavailableView(model.busy ? "正在读取相机素材" : "连接相机，浏览素材", systemImage: "camera.on.rectangle",
                                               description: Text(model.busy ? "素材会分批显示" : "先完成蓝牙配对，再连接相机热点"))
                    } else if model.filteredMedia.isEmpty {
                        ContentUnavailableView("没有匹配的素材", systemImage: "magnifyingglass", description: Text("试试其他筛选条件或文件名"))
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)], alignment: .leading, spacing: 16) {
                                ForEach(model.filteredMedia) { item in mediaCard(item) }
                            }.padding(20)
                        }
                    }
                }.frame(minWidth: 360, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                previewPane.frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.filteredMedia.count) 项素材 · 已选 \(model.selection.count) 项").font(.caption.weight(.medium))
                    if !model.connected {
                        Text("本地素材可离线预览").font(.caption2).foregroundStyle(.secondary)
                    } else if !model.scanComplete {
                        Text(model.busy ? "正在读取完整列表…" : "列表尚未完整，连接后刷新").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button("下载所选", systemImage: "arrow.down") { model.enqueue(model.selectedItems); tab = 1 }
                    .disabled(model.selectedItems.isEmpty || !model.connected || model.destination == nil || model.busy || model.enqueuing)
                Button("同步全部新增（\(model.remainingCount)）") { model.enqueue(model.media); tab = 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.scanComplete || !model.connected || model.destination == nil || model.remainingCount == 0 || model.enqueuing)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
    private func mediaCard(_ item: MediaItem) -> some View {
        let selected = model.selection.contains(item.id)
        let previewing = model.previewItem?.id == item.id
        return VStack(alignment: .leading, spacing: 0) {
            Button { model.preview(item) } label: {
                // 图片的固有宽高不能参与网格列宽计算；按分配尺寸裁切，避免宽图撑开卡片。
                GeometryReader { geometry in
                    ZStack(alignment: .bottomTrailing) {
                        Color(nsColor: .controlBackgroundColor)
                        if let thumbnail = model.thumbnails[item.version] {
                            Image(nsImage: thumbnail).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        } else {
                            Image(systemName: item.isVideo ? "video" : "photo").font(.title).foregroundStyle(.tertiary)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                        if item.isVideo {
                            Label(duration(item.duration), systemImage: "play.fill").font(.caption2.weight(.medium))
                                .padding(.horizontal, 7).padding(.vertical, 4).background(.regularMaterial, in: Capsule()).padding(7)
                        }
                    }
                }.frame(height: 128).clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).accessibilityLabel("预览 \(item.filename)").padding(8)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 7) {
                    Toggle("选择 \(item.filename)", isOn: Binding(get: { model.selection.contains(item.id) }, set: {
                        if $0 { model.selection.insert(item.id) } else { model.selection.remove(item.id) }
                    })).labelsHidden().toggleStyle(.checkbox)
                    Text(item.filename).font(.caption.weight(.medium)).lineLimit(2).truncationMode(.middle)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading).help(item.filename)
                }
                HStack {
                    Text(size(item.size)); Spacer(minLength: 4); Text(item.storage.title)
                }.font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Text(item.dayFolder).font(.caption2).foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    if model.completedVersions.contains(item.version) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("原片已同步")
                    }
                    Button("预览") { model.preview(item) }.font(.caption).buttonStyle(.borderless)
                }
            }.padding(.horizontal, 10).padding(.bottom, 12)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background(previewing ? Color.accentColor.opacity(0.06) : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected || previewing ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.15), lineWidth: selected ? 2 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .task(id: item.version + String(model.connected)) { await model.thumbnail(item) }
            .contextMenu {
                Button("预览") { model.preview(item) }
                Button("下载原片") { model.enqueue([item]) }.disabled(!model.connected || model.destination == nil)
            }
    }
    private var previewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("素材预览").font(.subheadline.weight(.semibold))
                    Spacer()
                    if let item = model.previewItem {
                        Text(item.isVideo ? "视频" : "照片").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let player = model.player {
                    NativeVideoPlayer(player: player).aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity).background(.black).clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack(spacing: 8) {
                        Button("播放", systemImage: "play.fill") { player.play() }
                        Button("暂停", systemImage: "pause.fill") { player.pause() }
                        Spacer(minLength: 0)
                        Button { player.seek(to: .zero); player.play() } label: { Image(systemName: "arrow.counterclockwise") }.help("从头播放").accessibilityLabel("从头播放")
                    }.controlSize(.small)
                } else if let image = model.previewImage {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34)).foregroundStyle(.tertiary)
                        Text(model.previewItem == nil ? "选择素材查看预览" : "正在准备预览").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).frame(height: 170)
                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
                if let item = model.previewItem {
                    Text(item.filename).font(.callout.weight(.semibold)).lineLimit(3).textSelection(.enabled)
                    Text(model.previewStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    VStack(spacing: 10) {
                        LabeledContent("存储来源", value: item.storage.title)
                        LabeledContent("拍摄日期", value: item.dayFolder)
                        LabeledContent("原片大小", value: size(item.size))
                        if item.isVideo { LabeledContent("视频时长", value: duration(item.duration)) }
                    }.font(.caption)
                    if model.previewNeedsOriginal {
                        Button("下载原片并预览", systemImage: "arrow.down") { model.enqueue([item]) }
                            .disabled(!model.connected || model.destination == nil)
                    }
                    DisclosureGroup("文件路径") { Text(item.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 6) }
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .textBackgroundColor))
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
