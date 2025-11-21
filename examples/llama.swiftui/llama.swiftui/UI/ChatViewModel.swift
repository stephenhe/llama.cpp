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
    
    // 在 Manager 初始化时定义全局人设
    private let baseSystemPrompt = """
    你是一个精通Swift语言的资深iOS工程师。
    回答问题时请优先提供代码示例。
    """
    
    // System Prompt
    private let systemPrompt = """
    你是一个拥有记忆的智能助手。为了方便程序处理，你必须**仅输出 JSON 格式**。
        
    【当前时间】：{{current_time}}

    请根据用户输入判断意图：
    1. 【闹钟】(alarm)：相对时间存 "delay_minutes" (Int)，绝对时间存 "time" (HH:mm)。
    2. 【记账】(accounting)：提取 "item" 和 "price"。
    3. 【闲聊】(chat)：**请阅读历史记录**，像正常人一样对话，将回复内容存入 "reply"。
    4. 【运行指令】(shortcut)：如果用户想执行手机操作（如省电模式、打开支付码），提取指令名称填入 "name"。
       JSON: {"tool": "shortcut", "args": {"name": "打开省电模式"}}

    JSON 格式示例：
    {"tool": "alarm", "args": {"delay_minutes": 10}}
    {"tool": "chat", "args": {"reply": "你好小明，我记得你。"}}
    """
    
    private var backgroundObserver: NSObjectProtocol?
    
    // MARK: - 初始化
    init() {
        
        loadModelsFromDisk()
        
        // 自动加载默认模型
        if let url = defaultModelUrl {
            Task { try? await loadModel(modelUrl: url) }
        }
        
        setupLifecycleObserver()
    }
    
    deinit {
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setupLifecycleObserver() {
        // 监听 "App 即将失去活跃" (切后台前的一瞬间)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("📱 App 即将进入后台，正在停止 LLM...")
            self?.stop() // 调用你的 stop 方法，取消 Task
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
    
    /// 发送指令 (支持图片内容)
    /// - Parameters:
    ///   - text: 用户输入的指令或问题
    ///   - imageContext: (可选) 图片识别出的文字内容
    ///   - speechService: 语音服务
    func send(text: String, imageContext: String? = nil, speechService: SpeechService?) {
        guard isModelLoaded && !isBusy else { return }
        
        self.speechService = speechService
        self.isBusy = true
        self.recognizedIntent = nil
        self.messageLog = "" // 清空实时流显示
        
        // --- 1. 构建内容 (核心修改) ---
        
        var actualContent = text // 给模型看的内容 (包含 OCR 文本)
        var displayContent = text // 给用户看的内容 (保持清爽)
        
        if let imgText = imageContext {
            // ✅ 使用优化后的 Prompt
            actualContent = """
            [图片上下文]
            以下是图片OCR识别结果（可能存在排版混乱，请尝试理解语义）：
            \"\"\"
            \(imgText)
            \"\"\"
            
            [任务]
            基于上述图片内容，执行用户指令：\(text)
            """
            
            displayContent = "[图片] \(text)"
        }
        
        // --- 2. 用户消息入库 ---
        
        // 使用 uiContent 字段区分展示内容和实际内容
        let userMsg = ChatMessage(role: .user,
                                  content: actualContent,   // 存入包含 OCR 的长文本，保持上下文记忆
                                  uiContent: displayContent) // 界面只显示 "[图片] ..."
        history.append(userMsg)
        
        // --- 3. 构建 Prompt ---
        // 直接使用 actualContent 构建，模型就能“看见”图片内容了
        let fullPrompt = buildQwenPrompt(userText: actualContent)
        
        print("🚀 Prompt 发送中...")
        
        generationTask = Task {
            var fullResponseBuffer = ""
            var tempBuffer = ""
            var ttsBuffer = ""
            var isJsonMode = false
            var isFirstToken = true
            // 🔥 新增：JSON 花括号计数器
            var braceDepth = 0
            var hasStartedJSON = false
            
            do {
                let stream = await llmService.streamChat(prompt: fullPrompt)
                
                for try await token in stream {
                    // --- A. 缓冲区过滤 (Qwen 特殊标记) ---
                    tempBuffer += token
                    
                    if tempBuffer.contains("<|im_end|>") || tempBuffer.contains("<|endoftext|>") { break }
                    
                    // 如果碎片太短且包含敏感字符，先扣留
                    if tempBuffer.count < 20 && (tempBuffer.contains("<") || tempBuffer.contains("|")) { continue }
                    
                    let cleanToken = tempBuffer
                    tempBuffer = ""
                    
                    fullResponseBuffer += cleanToken
                    
                    for char in cleanToken {
                        if char == "{" {
                            braceDepth += 1
                            hasStartedJSON = true
                        } else if char == "}" {
                            braceDepth -= 1
                        }
                    }
                    
                    // 只有当已经开始了 JSON，且深度回到了 0，说明一个完整的 JSON 结束了
                    if hasStartedJSON && braceDepth <= 0 {
                        print("✂️ 检测到 JSON 闭合，强制停止生成。")
                        
                        // 如果是流式显示，把最后一个 token 加上
                        // (根据你的 UI 逻辑决定是否需要这一步，通常加上比较好)
                        await MainActor.run { self.messageLog += cleanToken }
                        
                        break // 🚫 立即跳出循环，不再接收后续的重复内容
                    }
                    
                    
                    // --- B. 首字检测 (JSON vs Chat) ---
                    if isFirstToken {
                        let trimmed = cleanToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            isJsonMode = trimmed.hasPrefix("{")
                            isFirstToken = false
                        }
                    }
                    
                    // --- C. UI 刷新与 TTS ---
                    if isJsonMode {
                        // JSON 模式：界面不显示流式文字 (或者显示 Loading)
                        await MainActor.run {
                            if self.messageLog.isEmpty { self.messageLog = "🔄 正在分析..." }
                        }
                    } else {
                        // 聊天模式：实时刷新
                        await MainActor.run {
                            if self.messageLog == "🔄 正在分析..." { self.messageLog = "" }
                            self.messageLog += cleanToken
                        }
                        
                        ttsBuffer += cleanToken
                        if shouldSpeak(buffer: ttsBuffer) {
                            let textToSpeak = ttsBuffer
                            ttsBuffer = ""
                            await MainActor.run { self.speechService?.speak(textToSpeak) }
                        }
                    }
                }
                
                // --- 4. 生成结束收尾 ---
                
                // 清洗最终文本
                let finalCleanText = fullResponseBuffer.replacingOccurrences(of: "<|im_end|>", with: "")
                                                       .replacingOccurrences(of: "<|endoftext|>", with: "")
                
                if isJsonMode {
                    // A. JSON 模式：解析意图
                    let intent = await llmService.parseIntent(from: finalCleanText)
                    
                    await MainActor.run {
                        var display: String? = nil
                        var hide = false
                        
                        switch intent {
                        case .chat(let args):
                            display = args.reply
                            hide = false
                        case .accounting, .alarm:
                            hide = true // 指令类消息在气泡列表中隐藏 (因为有卡片)
                        case .shortcut(let args):
                            // URL 编码 (防止中文乱码)
                            let encodedName = args.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            if let url = URL(string: "shortcuts://run-shortcut?name=\(encodedName)") {
                                
                                // 打开 Shortcuts App
                                UIApplication.shared.open(url)
                                
                                self.speechService?.speak("正在为您运行 \(args.name)")
                            }
                            hide = true
                        case .unknown:
                            display = finalCleanText // 解析失败显示原文
                            hide = false
                        }
                        
                        // 存入 AI 回复 (JSON) 以维持上下文
                        let aiMsg = ChatMessage(role: .assistant,
                                                content: finalCleanText,
                                                uiContent: display,
                                                isHidden: hide)
                        self.history.append(aiMsg)
                        self.messageLog = ""
                        
                        self.handleIntent(intent)
                    }
                } else {
                    // B. 聊天模式
                    if !ttsBuffer.isEmpty {
                        let remaining = ttsBuffer
                        await MainActor.run { self.speechService?.speak(remaining) }
                    }
                    
                    await MainActor.run {
                        let aiMsg = ChatMessage(role: .assistant, content: finalCleanText)
                        self.history.append(aiMsg)
                        self.messageLog = ""
                    }
                }
                
            } catch {
                await MainActor.run {
                    let errorMsg = ChatMessage(role: .assistant, content: "❌ Error: \(error.localizedDescription)")
                    self.history.append(errorMsg)
                }
            }
            
            await MainActor.run { self.isBusy = false }
        }
    }
    
    private func send(text: String, speechService: SpeechService?) {
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
        
        print("prompt: \(fullPrompt)")
        
        generationTask = Task {
            var fullResponseBuffer = ""
            var ttsBuffer = ""
            var isJsonMode = false
            var isFirstToken = true
            
            // 🔥 新增：JSON 花括号计数器
            var braceDepth = 0
            var hasStartedJSON = false
            
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
                    
                    for char in cleanToken {
                        if char == "{" {
                            braceDepth += 1
                            hasStartedJSON = true
                        } else if char == "}" {
                            braceDepth -= 1
                        }
                    }
                    
                    // 只有当已经开始了 JSON，且深度回到了 0，说明一个完整的 JSON 结束了
                    if hasStartedJSON && braceDepth <= 0 {
                        print("✂️ 检测到 JSON 闭合，强制停止生成。")
                        
                        // 如果是流式显示，把最后一个 token 加上
                        // (根据你的 UI 逻辑决定是否需要这一步，通常加上比较好)
                        await MainActor.run { self.messageLog += cleanToken }
                        
                        break // 🚫 立即跳出循环，不再接收后续的重复内容
                    }
                    
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
                        var displayContent: String? = nil
                        var shouldHide = false
                        
                        switch intent {
                        case .chat(let args):
                            // 1. 闲聊模式：UI 显示 args.reply，不隐藏
                            displayContent = args.reply
                            shouldHide = false
                            
                        case .accounting, .alarm:
                            // 2. 功能模式：UI 隐藏气泡 (因为有卡片显示了)，但历史要存 JSON
                            shouldHide = true
                            
                        case .shortcut(let args):
                            // URL 编码 (防止中文乱码)
                            let encodedName = args.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            if let url = URL(string: "shortcuts://run-shortcut?name=\(encodedName)") {
                                
                                // 打开 Shortcuts App
                                UIApplication.shared.open(url)
                                
                                self.speechService?.speak("正在为您运行 \(args.name)")
                            }
                            shouldHide = true
                            
                        case .unknown:
                            // 3. 解析失败：显示原始文本用于调试
                            shouldHide = false
                        }
                        
                        // 构造消息：content 存原始 JSON (维护上下文)，uiContent 存回复 (给用户看)
                        let aiMsg = ChatMessage(role: .assistant,
                                                content: finalCleanText, // 存 {"tool":...}
                                                uiContent: displayContent,    // 存 "你好"
                                                isHidden: shouldHide)         // 设为隐藏
                        self.history.append(aiMsg)
                        
                        // 2. 清空流式显示的缓存 (防止界面上残留)
                        self.messageLog = ""
                        
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
            
        case .shortcut(let args):
            // URL 编码 (防止中文乱码)
            let encodedName = args.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "shortcuts://run-shortcut?name=\(encodedName)") {
                
                // 打开 Shortcuts App
                UIApplication.shared.open(url)
                
                self.speechService?.speak("正在为您运行 \(args.name)")
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
        // 1. System (带时间)
        let timeStr = getCurrentTimeStr()
        let dynamicSystem = systemPrompt.replacingOccurrences(of: "{{current_time}}", with: timeStr)
        
        // ✅ 修复：确保 System 后有换行
        var fullPrompt = "<|im_start|>system\n\(dynamicSystem)<|im_end|>\n"
        
        // 2. History (清洗与伪造)
        // 必须 dropLast，因为当前问题在第 3 步加
        let recentHistory = history.dropLast().suffix(6)
        
        for msg in recentHistory {
            var content = msg.content
            
            // 🛠️ 【关键欺骗】如果历史记录是纯文本，强制包装成 JSON
            // 这样模型看到的所有历史都是合规的 JSON，它就会乖乖听话
            if msg.role == .assistant && !content.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                // 伪造成 chat 工具的输出
                // 注意：这里要转义引号，为了简单演示直接拼接
                content = "{\"tool\": \"chat\", \"args\": {\"reply\": \"\(content)\"}}"
            }
            
            if msg.isHidden {
                continue
            }
            
            // ✅ 修复：确保前后都有换行
            fullPrompt += "<|im_start|>\(msg.role.rawValue)\n\(content)<|im_end|>\n"
        }
        
        // 3. Trigger
        // ✅ 修复：确保 Assistant 后有换行
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
    
    // 新增：发送带图片信息的请求
    func sendImageMessage(imageText: String, userQuery: String) {
        guard isModelLoaded && !isBusy else { return }
        
        // 1. 构建一个特殊的 Prompt，把图片内容作为背景知识注入
        let imageContext = """
        【系统检测到用户上传了一张图片，内容如下】：
        \"\"\"
        \(imageText)
        \"\"\"
        """
        
        // 2. 构造历史消息 (让用户看到自己发了图)
        // 这里我们存一个特殊的标记，或者直接显示"[图片上传]"
        let userMsg = ChatMessage(role: .user, content: "[上传了图片] \(userQuery)")
        history.append(userMsg)
        
        // 3. 临时插入一条 System 消息告诉模型图片内容
        // 注意：这条不存入 history，只在本次生成时拼接到 Prompt 里
        // 或者，我们可以直接修改 buildQwenPrompt 逻辑。
        
        // 简单做法：直接伪造用户的输入
        let augmentedQuery = "\(imageContext)\n\n用户问题：\(userQuery)"
        
        // 调用核心发送逻辑 (复用之前的 send 逻辑，只是 text 变了)
        // 注意：我们需要修改 send 方法，让它支持不重复 append userMsg，
        // 或者我们直接在这里手动调用底层逻辑。
        
        // 为了复用最简单，我们修改 send 方法支持 "内部 Prompt" 和 "显示 Prompt" 分离
        self.sendInternal(visibleText: "[图片] \(userQuery)", actualPromptText: augmentedQuery)
    }
    
    // 内部通用发送方法
    private func sendInternal(visibleText: String, actualPromptText: String) {
        guard isModelLoaded && !isBusy else { return }
        self.isBusy = true
        self.recognizedIntent = nil
        self.messageLog = ""
        
        // 1. 存入历史 (显示给用户看的内容)
        let userMsg = ChatMessage(role: .user, content: visibleText)
        history.append(userMsg)
        
        // 2. 构建 Prompt (使用包含图片信息的实际文本)
        let fullPrompt = buildQwenPrompt(userText: actualPromptText)
        
        generationTask = Task {
            // ... (这里完全复制之前 send 方法里 Task {} 的内容) ...
            // 记得把里面的 llmService.streamChat(prompt: fullPrompt) 用在这里
        }
    }
}
