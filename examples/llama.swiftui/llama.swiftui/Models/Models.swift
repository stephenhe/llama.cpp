//
//  Models.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/21.
//

import Foundation

// MARK: - 1. 基础参数结构 (Payloads)

struct AccountingArgs: Codable {
    let item: String
    let price: Double
}

struct AlarmArgs: Codable {
    let time: String?
    let delay_minutes: Int?
}

struct ChatArgs: Codable {
    let reply: String
}

struct ShortcutArgs: Codable {
    let name: String
}

// MARK: - 2. 核心意图枚举 (AIIntent)
// 你的 handleJsonIntent 方法 switch response.tool，说明 tool 必须是这个枚举

enum AIIntent {
    case accounting(AccountingArgs)
    case alarm(AlarmArgs)
    case chat(ChatArgs)
    case shortcut(ShortcutArgs)
    case unknown
}

// MARK: - 3. 顶层响应包装 (IntentResponse)
// 负责把 JSON {"tool": "...", "args": {...}} 转换成上面的 AIIntent

struct IntentResponse: Decodable {
    let tool: AIIntent // 核心：这里直接是枚举
    
    enum CodingKeys: String, CodingKey {
        case tool
        case args
    }
    
    // 自定义解码逻辑
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let toolName = try container.decode(String.self, forKey: .tool)
        
        switch toolName {
        case "accounting":
            let args = try container.decode(AccountingArgs.self, forKey: .args)
            self.tool = .accounting(args)
            
        case "alarm":
            let args = try container.decode(AlarmArgs.self, forKey: .args)
            self.tool = .alarm(args)
            
        case "chat":
            // 兼容处理：如果 args 是对象 {"reply": "..."}
            let args = try container.decode(ChatArgs.self, forKey: .args)
            self.tool = .chat(args)
            
        case "shortcut":
            // 兼容处理：如果 args 是对象 {"reply": "..."}
            let args = try container.decode(ShortcutArgs.self, forKey: .args)
            self.tool = .shortcut(args)
            
        default:
            self.tool = .unknown
        }
    }
}
