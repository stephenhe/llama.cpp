//
//  AIChatView.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/20.
//

import SwiftUI

struct AIChatView: View {
    // 引用我们写好的 Manager
    @StateObject var manager = LocalLLMManager()
    @StateObject var speechService = SpeechService() // 引入语音服务
    
    @State private var inputText: String = ""
    @State private var scrollProxy: ScrollViewProxy? = nil
    
    // 是否开启“自动朗读”模式
    @State private var autoSpeakMode = true
    
    // 简单的消息结构
    struct Message: Identifiable {
        let id = UUID()
        let content: String
        let isUser: Bool
    }
    
    @State private var messages: [Message] = []
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                
                // MARK: - 1. 顶部控制栏 (新增功能)
                HStack {
                    if manager.isBusy && !manager.isModelLoaded {
                        // 加载中状态
                        ProgressView()
                            .padding(.trailing, 5)
                        Text("正在初始化大脑...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else if manager.isModelLoaded {
                        // 已加载状态
                        HStack {
                            Image(systemName: "cpu.fill")
                                .foregroundColor(.green)
                            Text("Qwen-1.5B 在线")
                                .font(.caption)
                                .bold()
                        }
                        
                        Spacer()
                        
                        // 朗读开关
                        Toggle("自动朗读", isOn: $autoSpeakMode)
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                            .frame(width: 50)
                        
                        // 卸载按钮
                        Button(role: .destructive) {
                            withAnimation {
                                manager.unloadModel()
                            }
                        } label: {
                            Label("卸载", systemImage: "power")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        
                    } else {
                        // 未加载状态
                        HStack {
                            Image(systemName: "cpu")
                                .foregroundColor(.gray)
                            Text("模型未加载")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        
                        Spacer()
                        
                        // 加载菜单 (支持选模型)
                        Menu {
                            Section("内置模型") {
                                Button("Qwen 1.5B (默认)") {
                                    loadDefaultModel()
                                }
                            }
                            
                            if !manager.downloadedModels.isEmpty {
                                Section("已下载模型") {
                                    ForEach(manager.downloadedModels) { model in
                                        Button(model.name) {
                                            loadDocModel(filename: model.filename)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("加载模型", systemImage: "arrow.down.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .animation(.easeInOut, value: manager.isModelLoaded)
                
                // MARK: - 2. 业务卡片区域 (记账成功提示)
                if let expense = manager.parsedExpense {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        
                        VStack(alignment: .leading) {
                            Text(expense.item)
                                .font(.headline)
                            Text(expense.category ?? "杂项")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Text(String(format: "¥%.2f", expense.price))
                            .font(.title3)
                            .bold()
                            .foregroundColor(.blue)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(12)
                    .padding()
                    .transition(.scale.combined(with: .opacity))
                }
                
                // MARK: - 3. 聊天记录区域
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading) {
                            Text(manager.messageLog)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("bottom") // 用于自动滚动
                        }
                    }
                    .onChange(of: manager.messageLog) { _ in
                        // 自动滚动到底部
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                
                // MARK: - 4. 底部输入栏
                VStack(spacing: 0) {
                    Divider()
                    // 显示语音识别中的文字预览
                    if speechService.isRecording {
                        Text("正在听: \(speechService.detectedText)")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.top, 8)
                            .transition(.opacity)
                    }
                    HStack {
                        // 文本输入框
                        TextField("输入指令...", text: $inputText)
                            .textFieldStyle(.roundedBorder)
                            .disabled(speechService.isRecording) // 录音时禁用键盘输入
                        
                        if manager.isBusy {
                            Button {
                                manager.stop()
                            } label: {
                                Image(systemName: "stop.circle.fill")
                                    .resizable()
                                    .frame(width: 30, height: 30)
                                    .foregroundColor(.red)
                            }
                        } else {
                            // --- 语音/发送按钮逻辑 ---
                            HStack(spacing: 12) {
                                // 麦克风按钮 (长按说话，或点击切换状态，这里做成点击切换)
                                Button {
                                    toggleRecording()
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(speechService.isRecording ? Color.red : Color.blue)
                                            .frame(width: 35, height: 35)
                                            // 录音时有个呼吸动画
                                            .scaleEffect(speechService.isRecording ? 1.2 : 1.0)
                                            .animation(speechService.isRecording ? Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: speechService.isRecording)
                                        
                                        Image(systemName: speechService.isRecording ? "waveform" : "mic.fill")
                                            .foregroundColor(.white)
                                            .font(.system(size: 18))
                                    }
                                }
                                
                                // 如果输入框有字，显示发送按钮
                                if !inputText.isEmpty {
                                    Button {
                                        sendMessage()
                                    } label: {
                                        Image(systemName: "arrow.up.circle.fill")
                                            .resizable().frame(width: 30, height: 30).foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
                .background(Color(.systemBackground))
            }
            .navigationTitle("Jarvis Lite")
            .navigationBarTitleDisplayMode(.inline)
        }
        // 监听 LLM 生成状态，生成完后自动朗读
        .onChange(of: manager.isBusy) { isBusy in
            if !isBusy && autoSpeakMode && !manager.lastResponse.isEmpty {
                // 模型刚忙完，且有回复内容 -> 朗读
                speechService.speak(text: manager.lastResponse)
            }
        }
        // 监听语音服务有没有报错
        .alert(item: Binding<AlertItem?>(
            get: { speechService.errorMsg.map { AlertItem(message: $0) } },
            set: { _ in speechService.errorMsg = nil }
        )) { item in
            Alert(title: Text("错误"), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
    }
    
    // MARK: - 逻辑控制
        
    func toggleRecording() {
        if speechService.isRecording {
            // 1. 停止录音
            speechService.stopRecording()
            
            // 2. 稍微延迟一下，把识别到的文字发出去
            // 为什么要延迟？因为 stopRecording 后 recognitionTask 可能还会回调最后一次结果
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let text = speechService.detectedText
                if !text.isEmpty {
                    // 赋值给 manager 处理
                    manager.send(text: text)
                    // 清空识别缓存
                    speechService.detectedText = ""
                }
            }
        } else {
            // 停止当前的朗读（如果正在读）
            speechService.stopSpeaking()
            // 开始录音
            try? speechService.startRecording()
        }
    }
    
    func sendMessage() {
        guard !inputText.isEmpty else { return }
        let text = inputText
        inputText = ""
        
        // 收起键盘
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        manager.send(text: text)
    }
    
    func loadDefaultModel() {
        if let url = Bundle.main.url(forResource: "qwen2.5-1.5b-instruct-q4_k_m", withExtension: "gguf", subdirectory: "models") {
            Task {
                try? await manager.loadModel(modelUrl: url)
            }
        } else {
            manager.messageLog += "❌ 找不到内置模型文件，请检查 Bundle。\n"
        }
    }
    
    func loadDocModel(filename: String) {
        let url = manager.getDocumentsDirectory().appendingPathComponent(filename)
        Task {
            try? await manager.loadModel(modelUrl: url)
        }
    }
}

// 辅助 Alert 结构
struct AlertItem: Identifiable {
    var id = UUID()
    var message: String
}

#Preview {
    AIChatView()
}
