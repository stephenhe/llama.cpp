//
//  SpeechService.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/20.
//

import Foundation
import Speech
import AVFoundation

@MainActor
class SpeechService: NSObject, ObservableObject, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate {
    
    // --- 状态 ---
    @Published var isRecording = false
    @Published var isSpeaking = false
    @Published var errorMsg: String?
    @Published var detectedText: String = "" // 实时识别到的文字
    
    // --- 核心对象 ---
    // 1. 听 (STT)
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) // 指定中文
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    // 2. 说 (TTS)
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    override init() {
        super.init()
        speechSynthesizer.delegate = self
        speechRecognizer?.delegate = self
        requestPermissions()
    }
    
    // MARK: - 权限请求
    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized: break
                case .denied: self.errorMsg = "语音识别权限被拒绝"
                case .restricted: self.errorMsg = "语音识别受限"
                case .notDetermined: self.errorMsg = "等待授权"
                @unknown default: break
                }
            }
        }
    }
    
    // MARK: - 听 (Speech to Text)
    
    func startRecording() throws {
        // 1. 如果正在识别，先停止
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
        // 2. 配置音频会话 (非常重要：PlayAndRecord 允许同时录音和播放)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: .defaultToSpeaker)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        // 3. 创建识别请求
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        
        // 允许部分结果 (实时显示说话内容)
        recognitionRequest.shouldReportPartialResults = true
        
        // 4. 配置输入节点
        let inputNode = audioEngine.inputNode
        
        // 5. 开始识别任务
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            var isFinal = false
            
            if let result = result {
                // 更新识别到的文字
                self.detectedText = result.bestTranscription.formattedString
                isFinal = result.isFinal
            }
            
            if error != nil || isFinal {
                // 结束录音清理工作
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                self.recognitionTask = nil
                self.isRecording = false
            }
        }
        
        // 6. 监听麦克风数据并喂给识别器
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, when) in
            self.recognitionRequest?.append(buffer)
        }
        
        // 7. 启动引擎
        audioEngine.prepare()
        try audioEngine.start()
        
        self.detectedText = ""
        self.isRecording = true
    }
    
    func stopRecording() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        isRecording = false
    }
    
    // MARK: - 说 (Text to Speech)
    
    func speak(_ text: String) {
        
        // 确保 AudioSession 设置为播放模式
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: .duckOthers)
        try? session.setActive(true)
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN") // 中文语音
        utterance.rate = 0.52 // 稍微快一点点更自然
        utterance.pitchMultiplier = 1.0 // 音调
        
        speechSynthesizer.speak(utterance)
        
        if !isSpeaking {
            self.isSpeaking = true
        }
    }
    
    func stopSpeaking() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    // 监听说完的时候
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // 只有当队列为空时，才标记为停止
        // 注意：这里不能简单设为 false，因为可能队列里还有下一句。
        // 简单处理：我们通常依赖 UI 状态，或者在 LocalLLMManager 里控制。
        // 这里为了简化，暂不处理复杂状态，UI 上用 isSpeaking 仅做参考。
    }
}
