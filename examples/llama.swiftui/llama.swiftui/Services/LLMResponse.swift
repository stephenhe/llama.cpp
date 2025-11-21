//
//  LLMResponse.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/20.
//

import Foundation


//struct LLMResponse: Decodable {
//    let intent: AIIntent
//    
//    // 定义 JSON 的键名
//    enum CodingKeys: String, CodingKey {
//        case tool
//        case args
//    }
//    
//    init(from decoder: Decoder) throws {
//        let container = try decoder.container(keyedBy: CodingKeys.self)
//        
//        // 1. 先读取 tool 字段，看看想干嘛
//        let toolName = try container.decode(String.self, forKey: .tool)
//        
//        // 2. 根据 tool 的值，去 args 里解码对应的结构体
//        switch toolName {
//        case "accounting":
//            let args = try container.decode(AccountingArgs.self, forKey: .args)
//            self.intent = .accounting(args)
//            
//        case "alarm":
//            let args = try container.decode(AlarmArgs.self, forKey: .args)
//            self.intent = .alarm(args)
//            
//        case "note":
//            let args = try container.decode(NoteArgs.self, forKey: .args)
//            self.intent = .note(args)
//            
//        case "chat":
//            // Chat 有时候 args 可能是个字符串，有时候是对象，看你 Prompt 怎么写
//            // 这里假设是对象: {"args": {"reply": "..."}}
//            let args = try container.decode(ChatArgs.self, forKey: .args)
//            self.intent = .chat(args)
//            
//        default:
//            print("⚠️ 未知工具类型: \(toolName)")
//            self.intent = .unknown
//        }
//    }
//}
