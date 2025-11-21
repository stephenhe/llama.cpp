//
//  IntentModels.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/20.
//

import Foundation

// MARK: - 1. 定义各个工具的参数结构
// 将每个意图的参数拆开，互不干扰

/// 记账参数
struct AccountingArgs: Decodable {
    let item: String
    let price: Double
}

/// 闹钟参数 (核心修改：增加了 delay_minutes)
struct AlarmArgs: Decodable {
    /// 绝对时间 (如 "08:00")
    let time: String?
    /// 相对时间 (如 20 分钟后)，用于 Swift 端计算
    let delay_minutes: Int?
}

/// 闲聊参数
struct ChatArgs: Decodable {
    let reply: String
}

// MARK: - 2. 定义意图枚举 (AIIntent)
// 这是我们在业务逻辑中主要使用的类型

enum AIIntent {
    case accounting(AccountingArgs)
    case alarm(AlarmArgs)
    case chat(ChatArgs)
    case unknown
}

// MARK: - 3. 定义顶层响应解析器 (IntentResponse)
// 负责根据 "tool" 字段的值，动态决定 args 该解析成哪个结构体

struct IntentResponse: Decodable {
    let tool: String
    let intent: AIIntent // 解析后的枚举结果
    
    // 定义 JSON 键名
    enum CodingKeys: String, CodingKey {
        case tool
        case args
    }
    
    // 自定义解码逻辑
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // 1. 先读 tool 字符串
        let toolName = try container.decode(String.self, forKey: .tool)
        self.tool = toolName
        
        // 2. 根据 tool 决定 args 的类型
        switch toolName {
        case "accounting":
            // 如果 args 也是 JSON 对象
            let args = try container.decode(AccountingArgs.self, forKey: .args)
            self.intent = .accounting(args)
            
        case "alarm":
            let args = try container.decode(AlarmArgs.self, forKey: .args)
            self.intent = .alarm(args)
            
        case "chat":
            // Chat 的 args 可能比较灵活，这里假设标准格式
            // 如果模型有时候输出纯字符串，需要额外处理，这里按标准对象处理
            let args = try container.decode(ChatArgs.self, forKey: .args)
            self.intent = .chat(args)
            
        default:
            // 未知工具
            self.intent = .unknown
        }
    }
}
