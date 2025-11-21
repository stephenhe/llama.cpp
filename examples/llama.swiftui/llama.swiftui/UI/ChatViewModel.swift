//
//  ChatViewModel.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/21.
//

import SwiftUI
import Combine

@MainActor
class ChatViewModel: ObservableObject {
    // MARK: - UI 状态
    @Published var messageLog: String = ""
    @Published var isBusy: Bool = false
    @Published var isModelLoaded: Bool = false
    
    // 业务状态卡片
    @Published var recognizedIntent: AIIntent?
    @Published var history: [ChatMessage] = []
    
    // 模型列表
    @Published var downloadedModels: [Model] = []
    @Published var undownloadedModels: [Model] = []
    
    // MARK: - 内部依赖
    // 核心服务 (Service)
    private let llmService = LocalLLMService()
    
    // 语音服务 (弱引用，由 View 注入)
    weak var speechService: SpeechService?
    
    // 任务句柄 (用于取消生成)
    private var generationTask: Task<Void, Never>?
    
    // 默认模型配置
    private var defaultModelUrl: URL? {
        Bundle.main.url(forResource: "qwen2.5-1.5b-instruct-q4_k_m", withExtension: "gguf", subdirectory: "models")
    }
    
    // System Prompt
    private let systemPrompt = """
    你是一个严格的指令解析引擎。你的唯一任务是输出 JSON。
    **严禁输出任何自然语言解释、Markdown 标记或多余的字符。**
    
    【当前时间参考】：{{current_time}}

    请根据逻辑判断用户意图：
    1. 【闹钟】(alarm)：
       - 相对时间（如“X分钟后”）：**禁止自己计算时间**，直接将分钟数填入 "delay_minutes" (Int)。
       - 绝对时间（如“早上8点”）：填入 "time" (HH:mm)。
    2. 【记账】(accounting)：提取 "item" (String) 和 "price" (Double)。
    3. 【闲聊】(chat)：如果用户输入不是指令，请生成一句简短回复填入 "reply"。

    JSON 输出示例：
    {"tool": "alarm", "args": {"delay_minutes": 20}}
    {"tool": "accounting", "args": {"item": "打车", "price": 35.5}}
    {"tool": "chat", "args": {"reply": "你好。"}}
    """
    
    // MARK: - 初始化
    init() {
        
        loadModelsFromDisk()
        
        // 自动加载默认模型
        if let url = defaultModelUrl {
            Task { try? await loadModel(modelUrl: url) }
        }
    }
    
    // MARK: - 1. 模型管理
    
    private func loadModelsFromDisk() {
        do {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let modelURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            
            downloadedModels = modelURLs.map { url in
                Model(name: url.deletingPathExtension().lastPathComponent, url: "", filename: url.lastPathComponent, status: "downloaded")
            }
        } catch {
            print("Error loading models: \(error)")
        }
    }
    
    func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func loadModel(modelUrl: URL?) async throws {
        guard let modelUrl else { return }
        guard !isBusy else { return }
        
        isBusy = true
        messageLog += "Loading...\n"
        
        do {
            // 调用 Service 加载
            try await llmService.loadModel(url: modelUrl)
            
            isModelLoaded = true
            messageLog += "✅ Loaded.\n"
            
            // 更新列表状态 (简单演示)
            if let index = undownloadedModels.firstIndex(where: { $0.name == modelUrl.lastPathComponent }) {
                downloadedModels.append(undownloadedModels[index])
                undownloadedModels.remove(at: index)
            }
            
        } catch {
            messageLog += "❌ Error: \(error.localizedDescription)\n"
        }
        isBusy = false
    }
    
    func unloadModel() {
        // 1. 停止生成任务
        self.stop()
        
        // 2. 更新 UI 状态 (MainActor)
        self.isModelLoaded = false
        self.isBusy = false
        messageLog += "\n🚫 Unloaded.\n"
        self.recognizedIntent = nil
        
        // 3. 异步调用 Service 的卸载 (Service 是 Actor)
        Task {
            await llmService.unloadModel()
            print("🗑️ Service 资源已释放")
        }
    }
    
    // MARK: - 2. 核心交互 (Send)
    
    func send(text: String, speechService: SpeechService?) {
        guard isModelLoaded && !isBusy else { return }
        
        self.speechService = speechService
        self.isBusy = true
        self.recognizedIntent = nil // 重置意图
        self.messageLog = "" // 清空实时流显示
                
        // 1. 【入栈】把用户的每句话立即存入历史
        let userMsg = ChatMessage(role: .user, content: text)
        history.append(userMsg)
        
        // 2. 构建 Prompt (建议带上历史记录，让 AI 有记忆)
        // 这里简单处理，如果想做多轮对话，buildQwenPrompt 需要读取 history
        let fullPrompt = buildQwenPrompt(userText: text)
        
        generationTask = Task {
            var fullResponseBuffer = ""
            var ttsBuffer = ""
            var isJsonMode = false
            var isFirstToken = true
            
            do {
                // ✅✅✅ 核心变化：使用 for await 循环读取流 ✅✅✅
                // 我们不再传递 callback，而是像读文件一样读 stream
                let stream = await llmService.streamChat(prompt: fullPrompt)
                
                var tempBuffer = "" // 新增：用于暂存碎片
                
                for try await token in stream {
                    // 1. 先把新 token 拼到暂存区
                    tempBuffer += token
                    
                    // 2. 检查暂存区是否包含完整标记，如果有，直接删掉
                    // 注意：这里要处理所有可能的标记
                    if tempBuffer.contains("<|im_end|>") || tempBuffer.contains("<|endoftext|>") {
                        // 发现结束符！意味着生成结束了
                        // 我们可以选择 break 循环，或者仅仅是把标记删掉并继续
                        // 通常遇到这个就可以停止生成了
                        break
                    }
                    
                    // 3. 关键逻辑：判断是否要把暂存区的内容吐出来
                    // 如果暂存区看起来像是标记的前缀（比如 "<" 或 "<|"），就先扣着不发
                    // 只有当确定它不是标记时，才吐出来
                    
                    // 简单策略：如果 buffer 长度较短且包含敏感字符，先扣留
                    if tempBuffer.count < 20 && (tempBuffer.contains("<") || tempBuffer.contains("|")) {
                        // 继续下一轮循环，等攒多了再判断
                        continue
                    }
                    
                    // 4. 吐出内容
                    // 能走到这里，说明 tempBuffer 里攒的肯定不是特殊标记
                    let textToProcess = tempBuffer
                    tempBuffer = "" // 清空暂存区
                    
                    let cleanToken = textToProcess // 已经不需要 replace 了，因为我们在上面 break 了
                    
//                    let cleanToken = token.replacingOccurrences(of: "<|im_end|>", with: "")
//                                          .replacingOccurrences(of: "<|endoftext|>", with: "")
//                    if cleanToken.isEmpty { continue }
                    
                    fullResponseBuffer += cleanToken
                    
                    // 2. 首字检测模式
                    if isFirstToken {
                        let trimmed = cleanToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            isJsonMode = trimmed.hasPrefix("{")
                            isFirstToken = false
                        }
                    }
                    
                    // 3. 分流处理
                    if isJsonMode {
                        // JSON 模式：只显示，不朗读
                        self.messageLog += cleanToken
                    } else {
                        // 聊天模式：显示 + 朗读
                        self.messageLog += cleanToken
                        ttsBuffer += cleanToken
                        
                        if shouldSpeak(buffer: ttsBuffer) {
                            let textToSpeak = ttsBuffer
                            ttsBuffer = ""
                            self.speechService?.speak(textToSpeak)
                        }
                    }
                }
                
                // 4. 生成结束
                let finalCleanText = fullResponseBuffer.replacingOccurrences(of: "<|im_end|>", with: "")
                                                       .replacingOccurrences(of: "<|endoftext|>", with: "")
                
                // 4. 生成结束
                if isJsonMode {
                    // A. 调用 Service 解析，并拿到返回值
                    let intent = await llmService.parseIntent(from: finalCleanText)
                    
                    // B. 更新 UI 和执行业务 (回到 MainActor)
                    await MainActor.run {
                        self.handleIntent(intent)
                    }
                } else {
                    // C. 聊天模式收尾
                    if !ttsBuffer.isEmpty {
                        let remaining = ttsBuffer
                        Task { @MainActor in
                            self.speechService?.speak(remaining)
                        }
                    }
                    
                    await MainActor.run {
                        // 1. 创建 AI 消息实体
                        let aiMsg = ChatMessage(role: .assistant, content: fullResponseBuffer)
                        
                        // 2. 存入历史记录
                        self.history.append(aiMsg)
                        
                        // 3. 清空流式缓存 (因为历史记录里已经有了，防止显示两份)
                        self.messageLog = ""
                    }
                }
                
            } catch {
                await MainActor.run {
                    let errorMsg = ChatMessage(role: .assistant, content: "❌ 生成出错: \(error.localizedDescription)")
                    self.history.append(errorMsg)
                }
            }
            
            await MainActor.run { self.isBusy = false }
        }
    }
    
    func stop() {
        // 这里的取消需要配合 Service 的 Task 句柄，或者简单地重置状态
        // 由于我们用了 AsyncStream，取消 Task 会自动中断流
        // 实际项目中建议在 Service 里持有 Task 并提供 cancel 方法
        generationTask?.cancel()
        isBusy = false
        messageLog += " [Stopped]"
    }
    
    // 辅助：清空对话
    func clearChat() {
        history.removeAll()
        messageLog = ""
        recognizedIntent = nil
    }
    
    // MARK: - 3. 业务逻辑分发
    
    private func handleIntent(_ intent: AIIntent) {
        // 更新 UI 状态
        self.recognizedIntent = intent
        
        switch intent {
        case .accounting(let args):
            // 记账逻辑
            print("💰 记账: \(args.item) - \(args.price)")
            speechService?.speak("已记账，\(args.item)，\(args.price)元。")
            
        case .alarm(let args):
            // 闹钟逻辑
            if let delay = args.delay_minutes {
                // 相对时间
                let targetDate = Date().addingTimeInterval(TimeInterval(delay * 60))
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                let timeStr = formatter.string(from: targetDate)
                
                // 为了 UI 显示，我们需要更新 intent 里的数据（如果需要）
                // 这里直接调度
                scheduleLocalNotification(at: targetDate)
                speechService?.speak("好的，\(delay)分钟后叫你。")
                
            } else if let timeStr = args.time {
                // 绝对时间
                scheduleLocalNotification(timeString: timeStr)
                speechService?.speak("没问题，闹钟定在\(timeStr)。")
            }
            
        case .chat(let args):
            // 纯聊天逻辑 (通常已经在流式里处理了，这里是兜底)
            // 如果流式里已经读了，这里就不用读了
            // 如果是 JSON 解析失败降级来的，可以在这里读
            if args.reply.isEmpty == false {
                speechService?.speak(args.reply)
            }
            
        case .unknown:
            print("⚠️ 未知指令")
        }
    }
    
    // MARK: - 辅助方法
    
    nonisolated private func shouldSpeak(buffer: String) -> Bool {
        let delimiters: Set<Character> = ["，", "。", "？", "！", ",", ".", "?", "!", "\n"]
        if let lastChar = buffer.trimmingCharacters(in: .whitespaces).last, delimiters.contains(lastChar) {
            return true
        }
        return buffer.count > 30
    }
    
    // MARK: - Prompt 构建逻辑 (放在 Manager 里)

    private func buildQwenPrompt(userText: String) -> String {
        // 1. 获取当前时间
        let timeStr = getCurrentTimeStr()
        
        // 2. 替换 System Prompt 中的时间占位符
        let dynamicSystemPrompt = systemPrompt.replacingOccurrences(of: "{{current_time}}", with: timeStr)
        
        var fullPrompt = "<|im_start|>system\n\(dynamicSystemPrompt)<|im_end|>\n"
                
        // 2. 拼接历史记忆 (核心修改)
        // 逻辑：从 history 中取出最近的对话，但要【排除】刚刚用户发的这一条
        // 因为刚刚发的那一条（userText）会在步骤 3 放在最后作为“触发器”
        
        // A. 去掉最后一条(也就是当前这一条)，只取之前的
        // B. suffix(10): 只取最近 10 条，防止 Prompt 太长爆显存 (滑动窗口)
        let contextMessages = history.dropLast().suffix(10)
        
        for msg in contextMessages {
            // Qwen 格式: <|im_start|>role\nContent<|im_end|>\n
            // msg.role.rawValue 应该是 "user" 或 "assistant"
            fullPrompt += "<|im_start|>\(msg.role.rawValue)\n\(msg.content)<|im_end|>\n"
        }
        
        // 3. 拼接当前用户的新问题 (触发器)
        fullPrompt += "<|im_start|>user\n\(userText)<|im_end|>\n<|im_start|>assistant\n"
        
        return fullPrompt
    }
    
    private func getCurrentTimeStr() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm (EEEE)"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: Date())
    }
    
    // MARK: - 系统通知 (闹钟)
    
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    
    func scheduleLocalNotification(at targetDate: Date? = nil, timeString: String? = nil) {
        // 再次检查权限
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus != .authorized {
                self.requestNotificationPermission()
                return
            }
        }
        
        var components: DateComponents?
        
        if let date = targetDate {
            components = Calendar.current.dateComponents([.hour, .minute], from: date)
        } else if let timeStr = timeString {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            if timeStr.count == 4 { formatter.dateFormat = "H:mm" }
            if let date = formatter.date(from: timeStr) {
                components = Calendar.current.dateComponents([.hour, .minute], from: date)
            }
        }
        
        guard let triggerComponents = components else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "⏰ 闹钟提醒"
        content.body = "时间到了！"
        content.sound = .default
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ 闹钟失败: \(error)")
            } else {
                print("✅ 闹钟已设定")
            }
        }
    }
}
