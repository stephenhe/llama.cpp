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
    
    @State private var inputText: String = ""
    @State private var scrollProxy: ScrollViewProxy? = nil
    
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
                    HStack {
                        TextField(manager.isModelLoaded ? "例如: 打车花了35" : "请先加载模型...", text: $inputText)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!manager.isModelLoaded || manager.isBusy)
                        
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
                            Button {
                                sendMessage()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .resizable()
                                    .frame(width: 30, height: 30)
                                    .foregroundColor(manager.isModelLoaded && !inputText.isEmpty ? .blue : .gray)
                            }
                            .disabled(!manager.isModelLoaded || inputText.isEmpty)
                        }
                    }
                    .padding()
                }
                .background(Color(.systemBackground))
            }
            .navigationTitle("AI 记账助手")
            .navigationBarTitleDisplayMode(.inline)
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

#Preview {
    AIChatView()
}
