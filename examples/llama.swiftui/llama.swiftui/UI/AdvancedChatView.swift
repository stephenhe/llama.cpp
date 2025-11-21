//
//  AdvancedChatView.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/20.
//

import SwiftUI

struct AdvancedChatView: View {
    @StateObject var manager = LocalLLMManager()
    @StateObject var speechService = SpeechService()
    @State private var inputText = ""
    
    var body: some View {
        VStack {
            // 1. 动态业务卡片区
            if let intent = manager.recognizedIntent {
                Group {
                    switch intent {
                    case .accounting(let args):
                        // 记账卡片
                        HStack {
                            Image(systemName: "yensign.circle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                            VStack(alignment: .leading) {
                                Text("记账成功").font(.headline)
                                Text(args.item).foregroundColor(.gray)
                            }
                            Spacer()
                            Text(String(format: "%.2f", args.price))
                                .font(.title)
                                .bold()
                        }
                    case .alarm(let args):
                        // ⏰ 闹钟卡片 (这是你要的效果)
                        HStack {
                            Image(systemName: "alarm.fill")
                                .font(.largeTitle) // 大图标
                                .foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text("闹钟已设定").font(.headline)
                                Text(args.time ?? "\(args.delay_minutes ?? 0)分钟后")
                                    .font(.caption).foregroundColor(.gray)
                            }
                            
                            Spacer()
                            
                            Text(args.time ?? "--:--")
                                .font(.system(size: 40, weight: .light, design: .rounded)) // 数码钟风格字体
                                .foregroundColor(.blue)
                        }
                        
                    default: EmptyView()
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .padding()
                .transition(.move(edge: .top).combined(with: .opacity)) // 进场动画
                .id("intent-card") // 强制刷新
            }
            
            // 2. 聊天记录
            ScrollViewReader { proxy in
                ScrollView {
                    Text(manager.messageLog)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("bottom")
                }
                .onChange(of: manager.messageLog) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            
            // 3. 底部语音栏
            HStack {
                // 录音按钮
                Button(action: toggleRecording) {
                    ZStack {
                        Circle()
                            .fill(speechService.isRecording ? Color.red : Color.blue)
                            .frame(width: 50, height: 50)
                        Image(systemName: speechService.isRecording ? "square.fill" : "mic.fill")
                            .foregroundColor(.white)
                    }
                }
                
                if !speechService.isRecording {
                    TextField("输入...", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("发送") {
                        sendText()
                    }
                    .disabled(inputText.isEmpty)
                } else {
                    Text("正在聆听...")
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .onAppear {
            // 加载你的模型
            if let url = Bundle.main.url(forResource: "qwen2.5-1.5b-instruct-q4_k_m", withExtension: "gguf", subdirectory: "models") {
                Task { try? await manager.loadModel(modelUrl: url) }
            }
        }
//        .animation(.spring(), value: manager.recognizedIntent) // 给卡片加个弹簧动画
    }
    
    func toggleRecording() {
        if speechService.isRecording {
            speechService.stopRecording()
            // 延迟一点点发送，确保拿到最后的文字
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let text = speechService.detectedText
                if !text.isEmpty {
                    manager.send(text: text, speechService: speechService)
                }
            }
        } else {
            // 停止当前的 TTS
            speechService.stopSpeaking()
            try? speechService.startRecording()
        }
    }
    
    func sendText() {
        // 键盘发送也要传 speechService 进去，这样返回的文字也会自动朗读！
        manager.send(text: inputText, speechService: speechService)
        inputText = ""
    }
}

#Preview {
    AdvancedChatView()
}
