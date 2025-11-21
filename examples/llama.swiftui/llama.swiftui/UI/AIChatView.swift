//
//  AIChatView.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/20.
//

import SwiftUI

struct AIChatView: View {
    // 1. 使用功能全集版的 Manager
    @StateObject var viewModel = ChatViewModel()
    // 2. 引入语音服务 (View 层持有，注入给 Manager)
    @StateObject var speechService = SpeechService()
    
    @State private var inputText = ""
    @State private var showClearAlert = false
    
    @State private var showImagePicker = false
    @State private var selectedImage: UIImage?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 1. 顶部状态
                statusHeader
                
                // 2. 意图卡片 (根据 viewModel.recognizedIntent 变化)
                if let intent = viewModel.recognizedIntent {
                    IntentCard(intent: intent)
                        .padding()
                        .transition(.move(edge: .top).combined(with: .opacity))
                        // 添加一个 id 确保状态变化时动画能触发
                        .id(UUID())
                }
                
                // 3. 消息列表
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            // 1. 渲染历史记录 (已完成的对话)
                            // 确保 ChatMessage 遵循 Identifiable
                            ForEach(viewModel.history.filter { !$0.isHidden }) { msg in
                                ChatBubble(message: msg)
                                    .id(msg.id) // 绑定 ID 用于滚动
                            }
                            
                            // 2. 渲染正在生成的流式气泡 (仅在聊天模式且有内容时显示)
                            // 这里的逻辑是：如果正在生成，且 messageLog 有字，说明是新的、还没存入 history 的内容
                            if viewModel.isBusy && !viewModel.messageLog.isEmpty {
                                HStack(alignment: .top, spacing: 10) {
                                    // 左侧 AI 头像
                                    Image(systemName: "cpu.fill")
                                        .padding(6)
                                        .background(Color.green.opacity(0.2))
                                        .clipShape(Circle())
                                        .foregroundColor(.green)
                                    
                                    // 流式文字内容
                                    Text(viewModel.messageLog)
                                        .padding(12)
                                        .background(Color(.systemGray6))
                                        .foregroundColor(.primary)
                                        .cornerRadius(16)
                                    
                                    Spacer()
                                }
                                .padding(.horizontal)
                                .id("streaming_bubble") // 给个 ID 方便滚动
                            }
                            
                            // 3. 底部锚点 (用于自动滚动)
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                        .padding(.vertical)
                    }
                    .onChange(of: viewModel.history.count) { _ in
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    // 监听流式内容变化 -> 滚到底部 (让你看到打字过程)
                    .onChange(of: viewModel.messageLog) { _ in
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                
                // 4. 输入栏
                inputArea
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("AI 助手") // 可以加个标题
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showClearAlert = true // 触发弹窗
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    // 只有当有历史记录时才显示按钮，避免误触
                    .disabled(viewModel.history.isEmpty && viewModel.messageLog.isEmpty)
                }
            }
            .alert("确认清空历史？", isPresented: $showClearAlert) {
                Button("取消", role: .cancel) { }
                Button("清空", role: .destructive) {
                    // 调用 Manager 的清空方法
                    withAnimation {
                        viewModel.clearChat()
                    }
                }
            } message: {
                Text("这将删除本次对话的所有记忆，操作无法撤销。")
            }
        }
    }
    
    // MARK: - 子视图拆分
    
    var statusHeader: some View {
        HStack {
            if viewModel.isModelLoaded {
                Label("Brain Online", systemImage: "cpu.fill")
                    .foregroundColor(.green)
                    .font(.caption).bold()
                Spacer()
                Button("卸载") {
                    withAnimation { viewModel.unloadModel() }
                }
                .tint(.red)
                .buttonStyle(.bordered)
                .font(.caption)
            } else {
                Text("Brain Offline")
                    .foregroundColor(.gray)
                    .font(.caption)
                Spacer()
                // 加载默认模型
                Button("加载") {
                    if let url = Bundle.main.url(forResource: "qwen2.5-1.5b-instruct-q4_k_m", withExtension: "gguf", subdirectory: "models") {
                        Task { try? await viewModel.loadModel(modelUrl: url) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .font(.caption)
            }
        }
        .padding()
        .background(Color(.systemGray6))
    }
    
    var inputArea: some View {
        HStack {
            // 📷 新增图片按钮
            Button {
                showImagePicker = true
            } label: {
                Image(systemName: "photo")
                    .foregroundColor(.blue)
            }
            
            VStack(spacing: 0) {
                Divider()
                
                // 显示语音识别预览
                if speechService.isRecording {
                    Text("正在听: \(speechService.detectedText)")
                        .font(.caption).foregroundColor(.blue)
                        .padding(.top, 8)
                }
                
                HStack {
                    // 文本输入
                    TextField("输入指令...", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isBusy || speechService.isRecording)
                    
                    if viewModel.isBusy {
                        // 停止按钮
                        Button { viewModel.stop() } label: {
                            Image(systemName: "stop.circle.fill")
                                .resizable().frame(width: 30, height: 30)
                                .foregroundColor(.red)
                        }
                    } else {
                        HStack(spacing: 12) {
                            // 🎤 语音按钮
                            Button {
                                toggleRecording()
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(speechService.isRecording ? Color.red : Color.blue)
                                        .frame(width: 35, height: 35)
                                        .scaleEffect(speechService.isRecording ? 1.2 : 1.0)
                                        .animation(speechService.isRecording ? Animation.easeInOut(duration: 0.8).repeatForever() : .default, value: speechService.isRecording)
                                    
                                    Image(systemName: speechService.isRecording ? "waveform" : "mic.fill")
                                        .foregroundColor(.white)
                                        .font(.system(size: 18))
                                }
                            }
                            
                            // ⬆️ 发送按钮 (仅当有文字时显示)
                            if !inputText.isEmpty {
                                Button {
                                    sendMessage()
                                } label: {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .resizable().frame(width: 30, height: 30)
                                        .foregroundColor(viewModel.isModelLoaded ? .blue : .gray)
                                }
                                .disabled(!viewModel.isModelLoaded)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemBackground))
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $selectedImage)
        }
        // 监听图片选择
        .onChange(of: selectedImage) { newImage in
            if let img = newImage {
                processImage(img)
            }
        }
        
    }
    
    // MARK: - 交互逻辑
    
    func sendMessage() {
        guard !inputText.isEmpty else { return }
        // 将 speechService 注入给 Manager，以便 Manager 能调用 speak
        viewModel.send(text: inputText, speechService: speechService)
        inputText = ""
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    func toggleRecording() {
        if speechService.isRecording {
            speechService.stopRecording()
            // 延迟一点点，确保拿到最后一句完整的话
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let text = speechService.detectedText
                if !text.isEmpty {
                    viewModel.send(text: text, speechService: speechService)
                    speechService.detectedText = "" // 清空缓存
                }
            }
        } else {
            speechService.stopSpeaking() // 打断正在说的
            try? speechService.startRecording()
        }
    }
    
    func processImage(_ image: UIImage) {
        // 1. 开始识别
        // 先显示一个临时的加载状态
        inputText = "" // 清空输入框
        
        // 这里可以加个全屏 Loading 或者 Toast
        // print("正在识别图片...")
        
        Task {
            // 2. 调用 Vision 服务提取文字
            if let extractedText = await VisionService.extractText(from: image) {
                
                // 3. 调用整合后的 send 方法
                // imageContext: OCR 结果
                // text: 用户的 Prompt (这里给一个默认的引导语，或者弹窗让用户输)
                
                // 场景 A: 默认让模型总结
                let userPrompt = "请分析这张图片的内容。如果是收据或菜单，请提取关键信息。"
                
                // 场景 B: 如果你想让用户输入，这里可以弹个框，把 extractedText 存起来，等用户点发送时再带上
                
                // 这里演示场景 A (直接发送)
                await MainActor.run {
                    viewModel.send(text: userPrompt,
                                   imageContext: extractedText,
                                   speechService: speechService)
                }
                
            } else {
                // 识别失败处理
                print("未能识别图片内容")
            }
        }
    }
}

// MARK: - 意图卡片组件 (保持不变)
struct IntentCard: View {
    let intent: AIIntent
    
    var body: some View {
        switch intent {
        case .accounting(let args):
            HStack {
                Image(systemName: "yensign.circle.fill").font(.largeTitle).foregroundColor(.orange)
                VStack(alignment: .leading) {
                    Text("记账成功").font(.headline)
                    Text(args.item).foregroundColor(.gray)
                }
                Spacer()
                Text(String(format: "%.2f", args.price)).font(.title).bold()
            }
            .padding()
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)
            
        case .alarm(let args):
            HStack {
                Image(systemName: "alarm.fill").font(.largeTitle).foregroundColor(.blue)
                VStack(alignment: .leading) {
                    Text("闹钟已设置").font(.headline)
                    // 优先显示相对时间，如果没有则显示绝对时间
                    if let delay = args.delay_minutes {
                        Text("\(delay)分钟后").foregroundColor(.gray).font(.caption)
                    }
                }
                Spacer()
                // 显示最终计算出的时间 (如果 args.time 有值)
                Text(args.time ?? "--:--").font(.system(size: 40, design: .rounded)).foregroundColor(.blue)
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(12)
            
        default: EmptyView()
        }
    }
    
}

#Preview {
    AIChatView()
}
