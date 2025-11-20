//
//  LocalLLMManager.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/20.
//

import Foundation
import SwiftUI

// MARK: - 数据模型定义

/// 模型文件信息
//struct Model: Identifiable, Equatable {
//    var id = UUID()
//    var name: String
//    var url: String
//    var filename: String
//    var status: String?
//}

/// 业务数据模型 (记账示例)
struct ExpenseItem: Codable, Identifiable {
    var id = UUID()
    let item: String
    let price: Double
    let category: String?
}

// MARK: - Manager 类定义

@MainActor
class LocalLLMManager: ObservableObject {
    
    // --- UI 绑定的公开状态 ---
    @Published var messageLog: String = ""           // 实时对话日志
    @Published var isBusy: Bool = false              // 是否正在生成
    @Published var isModelLoaded: Bool = false       // 模型是否加载完毕
    @Published var parsedExpense: ExpenseItem?       // 业务解析结果 (记账卡片数据)
    
    @Published var lastResponse: String = "" // 新增：专门用于 TTS 朗读的纯净文本
    
    // 模型列表管理 (保留 LlamaState 的功能)
    @Published var downloadedModels: [Model] = []
    @Published var undownloadedModels: [Model] = []
    
    // --- 内部私有属性 ---
    private var llamaContext: LlamaContext?
    private var generationTask: Task<Void, Never>?
    
    // 默认模型配置 (Qwen2.5-1.5B)
    private var defaultModelUrl: URL? {
        Bundle.main.url(forResource: "qwen2.5-1.5b-instruct-q4_k_m", withExtension: "gguf", subdirectory: "models")
    }
    
    // 系统提示词 (System Prompt) - 定义 App 的人格和输出格式
//    private let systemPrompt = """
//    你是一个智能记账助手。
//    用户输入一段自然语言，你提取其中的【消费项目】、【金额】和【类别】。
//    请严格输出 JSON 格式，不要包含 Markdown 标记，不要说废话。
//    格式示例：{"item": "打车", "price": 35.5, "category": "交通"}
//    """
    
    private let systemPrompt = """
    你是一个手机智能助手。请分析用户的自然语言指令，判断用户想要执行什么操作。
    支持的操作（Tool）有以下几种：
    1. "accounting": 记账。参数：item(项目), price(金额)
    2. "alarm": 设闹钟。参数：time(时间字符串), label(备注)
    3. "note": 记备忘。参数：content(内容)
    4. "chat": 普通聊天。参数：reply(回复内容)

    请严格输出 JSON 格式：
    {
        "tool": "accounting",
        "args": { "item": "咖啡", "price": 25 }
    }
    或者
    {
        "tool": "chat",
        "args": { "reply": "你好呀！" }
    }
    不要包含 Markdown，直接输出 JSON。
    """

    // MARK: - 初始化
    init() {
        loadModelsFromDisk()
        // 尝试自动加载默认模型
        if let url = defaultModelUrl {
            // 使用 Task 避免在 init 中阻塞
            Task { try? await loadModel(modelUrl: url) }
        }
    }

    // MARK: - 1. 模型文件管理
    
    private func loadModelsFromDisk() {
        do {
            let documentsURL = getDocumentsDirectory()
            let modelURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            
            downloadedModels = modelURLs.map { url in
                Model(name: url.deletingPathExtension().lastPathComponent,
                      url: "",
                      filename: url.lastPathComponent,
                      status: "downloaded")
            }
        } catch {
            print("Error loading models from disk: \(error)")
        }
    }

    func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    /// 加载模型核心方法
    func loadModel(modelUrl: URL?) async throws {
        guard let modelUrl else { return }
        guard !isBusy else { return }
        
        self.isBusy = true
        self.messageLog += "Loading model: \(modelUrl.lastPathComponent)...\n"
        
        // 放到后台线程加载，避免卡 UI
        await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                // 调用底层 C++ 初始化
                // 注意：假设 LlamaContext.create_context 是静态方法
                let context = try LlamaContext.create_context(path: modelUrl.path)
                
                await MainActor.run {
                    self.llamaContext = context
                    self.isModelLoaded = true
                    self.isBusy = false
                    self.messageLog += "✅ Model loaded successfully.\n"
                    self.updateDownloadedModels(modelName: modelUrl.lastPathComponent, status: "loaded")
                }
            } catch {
                await MainActor.run {
                    self.messageLog += "❌ Error loading model: \(error.localizedDescription)\n"
                    self.isBusy = false
                }
            }
        }.value
    }
    
    /// 卸载模型，释放内存
    func unloadModel() {
        // 1. 先停止可能正在进行的生成
        self.stop()
        
        // 2. 销毁 C++ 上下文 (Swift 会自动释放类实例)
        self.llamaContext = nil
        
        // 3. 更新状态
        self.isModelLoaded = false
        self.messageLog += "\n🚫 模型已卸载，内存已释放。\n"
        print("🗑️ 模型内存已释放")
    }
    
    private func updateDownloadedModels(modelName: String, status: String) {
        if let index = undownloadedModels.firstIndex(where: { $0.name == modelName }) {
            var model = undownloadedModels[index]
            model.status = status
            downloadedModels.append(model)
            undownloadedModels.remove(at: index)
        }
    }

    // MARK: - 2. 核心推理逻辑
    
    /// 发送用户指令
    func send(text: String) {
        guard let context = llamaContext else {
            messageLog += "⚠️ Please load a model first.\n"
            return
        }
        guard !isBusy else { return }
        
        isBusy = true
        parsedExpense = nil // 重置上一轮的业务数据
        
        // UI 上显示用户输入
        messageLog += "\n🧑‍💻: \(text)\n🤖: "
        
        // 1. 构建 Qwen 格式 Prompt (注入 System Prompt)
//        let fullPrompt = buildQwenPrompt(userText: text)
        let fullPrompt = buildSummarizePrompt(article: text)
        
        // 2. 开启后台任务 (Task.detached 防止卡死主线程)
        generationTask = Task.detached(priority: .userInteractive) { [weak self] in
            guard let self = self else { return }
            
            var fullAccumulatedText = "" // 用于累积完整的回答 (用于 JSON 解析)
            var displayBuffer = ""       // 【关键】用于暂存可能是乱码的片段
                
            // 定义我们要拦截的所有特殊标记
            let stopTokens = ["<|im_end|>", "<|endoftext|>"]
            
            // 3. 调用底层流式接口
            // 注意：context 这里是 Class 类型，如果是 Actor 需要 await
            await context.completion_with_callback(text: fullPrompt) { token in
                
                // 1. 检查任务取消
                if Task.isCancelled { return false }
                
                // 2. 累积全量文本 (用于最终的停止判断)
                fullAccumulatedText += token
                
                // 3. 【核心拦截逻辑】
                // 先把新 token 加到暂存区
                displayBuffer += token
                
                // 检查暂存区是否包含完整的停止标记
                for stopToken in stopTokens {
                    if displayBuffer.contains(stopToken) {
                        // 发现完整停止符！立即停止生成，并且不刷新 UI
                        return false
                    }
                }
                
                // 4. 【缓冲区刷新逻辑】
                // 我们需要判断：displayBuffer 是否可能是停止符的"一部分"？
                // 比如 "<|im" 就是停止符的前缀。
                
                var isPartialStop = false
                for stopToken in stopTokens {
                    // 如果停止符 以 displayBuffer 开头 (例如 stopToken是"<|im_end|>", buffer是"<|")
                    // 或者 displayBuffer 以停止符的一部分结尾
                    if stopToken.hasPrefix(displayBuffer) {
                        isPartialStop = true
                        break
                    }
                    // 处理 buffer 已经比 stopToken 长，但尾部包含 stopToken 前缀的情况
                    // (这种情况比较复杂，简单做法是只看 buffer 长度是否很短)
                }
                
                // 这里的逻辑简化版：
                // 只要 buffer 里包含了 "<" 或者 "|" 这种敏感字符，且长度比较短，我们就先暂存不发
                // 等 buffer 攒够了长度，确定不是停止符了，再一次性发出去
                
                if displayBuffer.count < 20 && (displayBuffer.contains("<") || displayBuffer.contains("|")) {
                    // 看起来像停止符的前缀，先扣下，不刷新 UI
                    // 继续下一轮循环，等拼全了再说
                    return true
                } else {
                    // 说明 buffer 里攒的肯定不是停止符（或者已经攒很长了都不是），放心放行
                    let textToDisplay = displayBuffer
                    displayBuffer = "" // 清空缓冲区
                    
                    Task { @MainActor in
                        self.messageLog += textToDisplay
                    }
                }
                
                return true // 继续生成
            }
            
            // 4. 生成结束，处理业务逻辑
            await self.handleBusinessLogic(fullText: fullAccumulatedText)
        }
    }
    
    /// 停止生成
    func stop() {
        generationTask?.cancel()
        generationTask = nil
        isBusy = false
        messageLog += " [Stopped]"
    }
    
    /// 清空上下文/屏幕
    func clear() {
        messageLog = ""
        parsedExpense = nil
    }

    // MARK: - 3. 业务辅助方法
    
    /// 构建 Qwen ChatML 格式 Prompt
    private func buildQwenPrompt(userText: String) -> String {
        return """
        <|im_start|>system
        \(systemPrompt)<|im_end|>
        <|im_start|>user
        \(userText)<|im_end|>
        <|im_start|>assistant
        
        """
    }
    
    /// 构建 Qwen ChatML 格式 Prompt
    private func buildSummarizePrompt(article: String) -> String {
        return """
        <|im_start|>system
        你是一个阅读助手。请阅读下面的文章，列出 3 个核心要点。
        <|im_end|>
        <|im_start|>user
        \(article)
        <|im_end|>
        <|im_start|>assistant
        """
    }
    
    /// 业务逻辑：尝试从回答中提取 JSON 并转为 Object
    private func handleBusinessLogic(fullText: String) async {
        // 先清洗掉结束符
        let cleanText = fullText.replacingOccurrences(of: "<|im_end|>", with: "")
                                .replacingOccurrences(of: "<|endoftext|>", with: "")
        
        guard let data = cleanText.data(using: .utf8) else { return }
        
        await MainActor.run {
            self.lastResponse = cleanText // <--- 赋值给这个新变量
            self.isBusy = false
            self.messageLog += "\n"
            do {
                // ✅ 开始解码
                let response = try JSONDecoder().decode(LLMResponse.self, from: data)
                
                // ✅ 路由分发 (编译器会强制你处理所有 case，非常安全)
                switch response.intent {
                case .accounting(let args):
                    // 这里的 args 自动就是 AccountingArgs 类型
                    print("💰 记账: \(args.item) - ¥\(args.price)")
                    // self.parsedExpense = ...
                    
                case .alarm(let args):
                    print("⏰ 设闹钟: \(args.time) 备注: \(args.label ?? "无")")
                    
                case .note(let args):
                    print("📝 记备忘: \(args.content)")
                    
                case .chat(let args):
                    // 闲聊直接显示
                    self.messageLog += "\n🤖: \(args.reply)"
                    
                case .unknown:
                    print("❓ 意图无法识别")
                }
                
            } catch {
                print("JSON 解析失败: \(error)")
                // 如果解析失败，说明模型可能没按 JSON 格式说话，
                // 此时可以把 cleanText 直接当做普通回复显示出来做兜底
                self.messageLog += "\n(非结构化回复): \(cleanText)"
            }
        }
    }
}
