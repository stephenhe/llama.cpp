//
//  LocalLLMService.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/20.
//

import Foundation

actor LocalLLMService {
    private var llamaContext: LlamaContext?
    
    // 状态标识
    var isModelLoaded: Bool { llamaContext != nil }
    
    // MARK: - 模型管理
    
    func loadModel(url: URL) throws {
        // 确保释放旧的
        llamaContext = nil
        let context = try LlamaContext.create_context(path: url.path)
        self.llamaContext = context
    }
    
    func unloadModel() {
        llamaContext = nil
    }
    
    // MARK: - 核心：流式推理桥接
    
    /// 输入 Prompt，返回一个异步的字符流
    /// ViewModel 只需要 for await 这个流即可，不需要关心底层回调
    func streamChat(prompt: String) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            guard let context = llamaContext else {
                continuation.finish(throwing: NSError(domain: "LLM", code: 404, userInfo: [NSLocalizedDescriptionKey: "模型未加载"]))
                return
            }
            
            // 在 Task 中执行 C++ 调用
            Task {
                // 调用底层的 completion_with_callback
                // 注意：这里假设 context 是线程安全的或已正确加锁
                // 如果 context 是 actor，需要 await
                await context.completion_with_callback(text: prompt) { token in
                    
                    // 检查任务取消
                    if Task.isCancelled {
                        continuation.finish()
                        return false
                    }
                    
                    // 将 token 发送给流
                    continuation.yield(token)
                    return true
                }
                
                // 完成
                continuation.finish()
            }
        }
    }
    
    // MARK: - 纯逻辑：解析意图
    // 把它放在这里是因为它属于“数据处理”，不依赖 UI
    func parseIntent(from text: String) -> AIIntent {
        // 1. 清洗字符串
        let cleanText = text.replacingOccurrences(of: "<|im_end|>", with: "")
                            .replacingOccurrences(of: "<|endoftext|>", with: "")
                            .replacingOccurrences(of: "```json", with: "")
                            .replacingOccurrences(of: "```", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 2. 提取 JSON 部分
        guard let start = cleanText.range(of: "{"),
              let end = cleanText.range(of: "}", options: .backwards) else {
            // 如果没找到 JSON 结构，视为普通聊天
            return .chat(ChatArgs(reply: cleanText))
        }
        
        let jsonString = String(cleanText[start.lowerBound..<end.upperBound])
        guard let data = jsonString.data(using: .utf8) else { return .unknown }
        
        // 3. 解码并转换
        do {
            // 这里利用我们在 Models 里写好的智能解码逻辑
            let response = try JSONDecoder().decode(IntentResponse.self, from: data)
            
            // IntentResponse.tool 已经是 AIIntent 枚举了，直接返回即可
            return response.tool
            
        } catch {
            print("Service 解析失败: \(error)")
            // 解析失败兜底：把原始清洗后的文本作为聊天内容返回
            return .chat(ChatArgs(reply: cleanText))
        }
    }
}
