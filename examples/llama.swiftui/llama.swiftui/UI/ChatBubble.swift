//
//  ChatBubble.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/21.
//

import SwiftUI

// 1. 聊天消息模型
struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    let role: ChatRole
    var content: String
    var isTyping = false
    var date: Date = Date()
    var uiContent: String?     // UI 显示文本 (仅 Chat 模式有值)
    var isHidden: Bool = false // 是否在列表中隐藏 (指令类消息设为 true)
    
    // 辅助属性：View 层直接调用这个获取显示内容
    var contentToDisplay: String {
        return uiContent ?? content
    }
        
    // 辅助属性：判断是否应该在 UI 上显示
    // System 消息通常是给模型看的“潜台词”，不应该显示在聊天气泡里
    var isVisible: Bool {
        return role != .system
    }
}

enum ChatRole: String, Codable {
    case system = "system"       // 💡 新增：系统指令 (导演)
    case user = "user"           // 用户 (演员A)
    case assistant = "assistant" // AI (演员B)
}

struct ChatBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            
            // 🤖 左侧：AI 的头像
            if message.role != .user {
                AvatarView()
            } else {
                Spacer() // 用户消息靠右，左边放 Spacer
            }
            
            // 💬 中间：消息气泡内容
            VStack(alignment: message.role == .user ? .trailing : .leading) {
                if message.isTyping && message.content.isEmpty {
                    // 1. 正在思考且内容为空 -> 显示加载动画
                    TypingIndicator()
                        .padding(12)
                        .background(bubbleColor)
                        .clipShape(bubbleShape)
                } else {
                    // 2. 显示文本 (支持 Markdown)
                    Text(.init(message.contentToDisplay)) // .init 开启 Markdown 解析
                        .font(.body)
                        .foregroundColor(textColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(bubbleColor)
                        .clipShape(bubbleShape)
                        // 允许长按复制
                        .textSelection(.enabled)
                }
            }
            
            // 👤 右侧：用户的头像 (可选，这里省略头像只靠右对齐)
            if message.role == .user {
                // 如果想要用户头像放在这里加
            } else {
                Spacer() // AI 消息靠左，右边放 Spacer
            }
        }
    }
    
    // MARK: - 样式属性
    
    private var bubbleColor: Color {
        message.role == .user ? .blue : Color(.systemGray6)
    }
    
    private var textColor: Color {
        message.role == .user ? .white : .primary
    }
    
    private var bubbleShape: some Shape {
        // iOS 16/17: 使用 UnevenRoundedRectangle 或者自定义 Corner
        // 这里使用通用的自定义扩展，实现"气泡尾巴"效果
        let corners: UIRectCorner = message.role == .user
            ? [.topLeft, .topRight, .bottomLeft] // 用户：右下角直角
            : [.topLeft, .topRight, .bottomRight] // AI：左下角直角
        
        return RoundedCorner(radius: 16, corners: corners)
    }
}

// MARK: - 辅助组件：AI 头像
struct AvatarView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 32, height: 32)
            
            Image(systemName: "cpu.fill")
                .font(.system(size: 16))
                .foregroundColor(.white)
        }
    }
}

// MARK: - 辅助组件：正在输入动画 (三个跳动的小点)
struct TypingIndicator: View {
    @State private var showDot = false
    
    var body: some View {
        HStack(spacing: 4) {
            Circle().opacity(showDot ? 1 : 0.3).scaleEffect(showDot ? 1 : 0.5)
            Circle().opacity(showDot ? 1 : 0.3).scaleEffect(showDot ? 1 : 0.5)
                .animation(.easeInOut(duration: 0.6).repeatForever().delay(0.2), value: showDot)
            Circle().opacity(showDot ? 1 : 0.3).scaleEffect(showDot ? 1 : 0.5)
                .animation(.easeInOut(duration: 0.6).repeatForever().delay(0.4), value: showDot)
        }
        .frame(height: 10)
        .foregroundColor(Color.gray)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) {
                showDot.toggle()
            }
        }
    }
}

// MARK: - 核心工具：自定义圆角 Shape
// 允许指定某几个角是圆的，某几个角是直的
struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

#Preview {
    ChatBubble(message: ChatMessage(role: .user, content: "我是小明", isTyping: true))
}
