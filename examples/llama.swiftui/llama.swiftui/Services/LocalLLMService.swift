//
//  LocalLLMService.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/20.
//

import Foundation
import BusinessChat

///
protocol LocalLLMService {
    /// 初始化模型（通常在App启动或进入特定功能页时预热）
    func loadModel(url: URL) async throws
    
    /// 核心流式对话接口
    /// - Parameters:
    ///   - prompt: 用户输入
    ///   - history: 上下文历史（可选）
    ///   - onToken: 回调闭包，每生成一个字调一次（用于打字机效果）
    /// - Returns:
//    func chat(prompt: String, history: [ChatMessage], onToken: @escaping (String) -> Void) async throws -> String
    
    /// 停止生成
    func stop()
    
    /// 释放模型（省电/省内存）
    func unload()
    
}
