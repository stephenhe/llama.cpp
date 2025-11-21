//
//  VisionService.swift
//  llama.swiftui
//
//  Created by stephenhe on 2025/11/21.
//

import Foundation
import Vision
import UIKit

class VisionService {
    
    /// 提取图片中的所有文字
    static func extractText(from image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        
        return await withCheckedContinuation { continuation in
            // 创建请求
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // 拼接所有识别到的文字
                let fullText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                continuation.resume(returning: fullText)
            }
            
            // "zh-Hans": 简体中文
            // "zh-Hant": 繁体中文
            // "en-US": 英语 (防止中英混排识别不出)
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            
            // 配置：精确优先
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            // 执行
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }
}
