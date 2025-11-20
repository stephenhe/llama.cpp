import Foundation
import llama

enum LlamaError: Error {
    case couldNotInitializeContext
}

func llama_batch_clear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], _ logits: Bool) {
    batch.token   [Int(batch.n_tokens)] = id
    batch.pos     [Int(batch.n_tokens)] = pos
    batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)
    for i in 0..<seq_ids.count {
        batch.seq_id[Int(batch.n_tokens)]![Int(i)] = seq_ids[i]
    }
    batch.logits  [Int(batch.n_tokens)] = logits ? 1 : 0

    batch.n_tokens += 1
}

actor LlamaContext {
    private var model: OpaquePointer
    private var context: OpaquePointer
    private var vocab: OpaquePointer
    private var sampling: UnsafeMutablePointer<llama_sampler>
    private var batch: llama_batch
    private var tokens_list: [llama_token]
    var is_done: Bool = false

    /// This variable is used to store temporarily invalid cchars
    private var temporary_invalid_cchars: [CChar]

    var n_len: Int32 = 1024
    var n_cur: Int32 = 0

    var n_decode: Int32 = 0

    init(model: OpaquePointer, context: OpaquePointer) {
        self.model = model
        self.context = context
        self.tokens_list = []
        self.batch = llama_batch_init(512, 0, 1)
        self.temporary_invalid_cchars = []
        let sparams = llama_sampler_chain_default_params()
        self.sampling = llama_sampler_chain_init(sparams)
        llama_sampler_chain_add(self.sampling, llama_sampler_init_temp(0.4))
        llama_sampler_chain_add(self.sampling, llama_sampler_init_dist(1234))
        vocab = llama_model_get_vocab(model)
    }

    deinit {
        print("💀 LlamaContext 正在析构，释放 C++ 内存...")
        llama_sampler_free(sampling)
        llama_batch_free(batch)
        llama_model_free(model)
        llama_free(context)
        llama_backend_free()
    }

    static func create_context(path: String) throws -> LlamaContext {
        llama_backend_init()
        var model_params = llama_model_default_params()

#if targetEnvironment(simulator)
        model_params.n_gpu_layers = 0
        print("Running on simulator, force use n_gpu_layers = 0")
#endif
        let model = llama_model_load_from_file(path, model_params)
        guard let model else {
            print("Could not load model at \(path)")
            throw LlamaError.couldNotInitializeContext
        }

        let n_threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        print("Using \(n_threads) threads")

        var ctx_params = llama_context_default_params()
        ctx_params.n_ctx = 4096
        ctx_params.n_threads       = Int32(n_threads)
        ctx_params.n_threads_batch = Int32(n_threads)

        let context = llama_init_from_model(model, ctx_params)
        guard let context else {
            print("Could not load context!")
            throw LlamaError.couldNotInitializeContext
        }

        return LlamaContext(model: model, context: context)
    }

    func model_info() -> String {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 256)
        result.initialize(repeating: Int8(0), count: 256)
        defer {
            result.deallocate()
        }

        // TODO: this is probably very stupid way to get the string from C

        let nChars = llama_model_desc(model, result, 256)
        let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nChars))

        var SwiftString = ""
        for char in bufferPointer {
            SwiftString.append(Character(UnicodeScalar(UInt8(char))))
        }

        return SwiftString
    }

    func get_n_tokens() -> Int32 {
        return batch.n_tokens;
    }

    func completion_init(text: String) {
        print("attempting to complete \"\(text)\"")

        tokens_list = tokenize(text: text, add_bos: true)
        temporary_invalid_cchars = []

        let n_ctx = llama_n_ctx(context)
        let n_kv_req = tokens_list.count + (Int(n_len) - tokens_list.count)

        print("\n n_len = \(n_len), n_ctx = \(n_ctx), n_kv_req = \(n_kv_req)")

        if n_kv_req > n_ctx {
            print("error: n_kv_req > n_ctx, the required KV cache size is not big enough")
        }

        for id in tokens_list {
            print(String(cString: token_to_piece(token: id) + [0]))
        }

        llama_batch_clear(&batch)

        for i1 in 0..<tokens_list.count {
            let i = Int(i1)
            llama_batch_add(&batch, tokens_list[i], Int32(i), [0], false)
        }
        batch.logits[Int(batch.n_tokens) - 1] = 1 // true

        if llama_decode(context, batch) != 0 {
            print("llama_decode() failed")
        }

        n_cur = batch.n_tokens
    }

    func completion_loop() -> String {
        var new_token_id: llama_token = 0

        new_token_id = llama_sampler_sample(sampling, context, batch.n_tokens - 1)

        if llama_vocab_is_eog(vocab, new_token_id) || n_cur == n_len {
            print("\n")
            is_done = true
            let new_token_str = String(cString: temporary_invalid_cchars + [0])
            temporary_invalid_cchars.removeAll()
            return new_token_str
        }

        let new_token_cchars = token_to_piece(token: new_token_id)
        temporary_invalid_cchars.append(contentsOf: new_token_cchars)
        let new_token_str: String
        if let string = String(validatingUTF8: temporary_invalid_cchars + [0]) {
            temporary_invalid_cchars.removeAll()
            new_token_str = string
        } else if (0 ..< temporary_invalid_cchars.count).contains(where: {$0 != 0 && String(validatingUTF8: Array(temporary_invalid_cchars.suffix($0)) + [0]) != nil}) {
            // in this case, at least the suffix of the temporary_invalid_cchars can be interpreted as UTF8 string
            let string = String(cString: temporary_invalid_cchars + [0])
            temporary_invalid_cchars.removeAll()
            new_token_str = string
        } else {
            new_token_str = ""
        }
        print(new_token_str)
        // tokens_list.append(new_token_id)

        llama_batch_clear(&batch)
        llama_batch_add(&batch, new_token_id, n_cur, [0], true)

        n_decode += 1
        n_cur    += 1

        if llama_decode(context, batch) != 0 {
            print("failed to evaluate llama!")
        }

        return new_token_str
    }

    func bench(pp: Int, tg: Int, pl: Int, nr: Int = 1) -> String {
        var pp_avg: Double = 0
        var tg_avg: Double = 0

        var pp_std: Double = 0
        var tg_std: Double = 0

        for _ in 0..<nr {
            // bench prompt processing

            llama_batch_clear(&batch)

            let n_tokens = pp

            for i in 0..<n_tokens {
                llama_batch_add(&batch, 0, Int32(i), [0], false)
            }
            batch.logits[Int(batch.n_tokens) - 1] = 1 // true

            llama_memory_clear(llama_get_memory(context), false)

            let t_pp_start = DispatchTime.now().uptimeNanoseconds / 1000;

            if llama_decode(context, batch) != 0 {
                print("llama_decode() failed during prompt")
            }
            llama_synchronize(context)

            let t_pp_end = DispatchTime.now().uptimeNanoseconds / 1000;

            // bench text generation

            llama_memory_clear(llama_get_memory(context), false)

            let t_tg_start = DispatchTime.now().uptimeNanoseconds / 1000;

            for i in 0..<tg {
                llama_batch_clear(&batch)

                for j in 0..<pl {
                    llama_batch_add(&batch, 0, Int32(i), [Int32(j)], true)
                }

                if llama_decode(context, batch) != 0 {
                    print("llama_decode() failed during text generation")
                }
                llama_synchronize(context)
            }

            let t_tg_end = DispatchTime.now().uptimeNanoseconds / 1000;

            llama_memory_clear(llama_get_memory(context), false)

            let t_pp = Double(t_pp_end - t_pp_start) / 1000000.0
            let t_tg = Double(t_tg_end - t_tg_start) / 1000000.0

            let speed_pp = Double(pp)    / t_pp
            let speed_tg = Double(pl*tg) / t_tg

            pp_avg += speed_pp
            tg_avg += speed_tg

            pp_std += speed_pp * speed_pp
            tg_std += speed_tg * speed_tg

            print("pp \(speed_pp) t/s, tg \(speed_tg) t/s")
        }

        pp_avg /= Double(nr)
        tg_avg /= Double(nr)

        if nr > 1 {
            pp_std = sqrt(pp_std / Double(nr - 1) - pp_avg * pp_avg * Double(nr) / Double(nr - 1))
            tg_std = sqrt(tg_std / Double(nr - 1) - tg_avg * tg_avg * Double(nr) / Double(nr - 1))
        } else {
            pp_std = 0
            tg_std = 0
        }

        let model_desc     = model_info();
        let model_size     = String(format: "%.2f GiB", Double(llama_model_size(model)) / 1024.0 / 1024.0 / 1024.0);
        let model_n_params = String(format: "%.2f B", Double(llama_model_n_params(model)) / 1e9);
        let backend        = "Metal";
        let pp_avg_str     = String(format: "%.2f", pp_avg);
        let tg_avg_str     = String(format: "%.2f", tg_avg);
        let pp_std_str     = String(format: "%.2f", pp_std);
        let tg_std_str     = String(format: "%.2f", tg_std);

        var result = ""

        result += String("| model | size | params | backend | test | t/s |\n")
        result += String("| --- | --- | --- | --- | --- | --- |\n")
        result += String("| \(model_desc) | \(model_size) | \(model_n_params) | \(backend) | pp \(pp) | \(pp_avg_str) ± \(pp_std_str) |\n")
        result += String("| \(model_desc) | \(model_size) | \(model_n_params) | \(backend) | tg \(tg) | \(tg_avg_str) ± \(tg_std_str) |\n")

        return result;
    }

    func clear() {
        tokens_list.removeAll()
        temporary_invalid_cchars.removeAll()
        llama_memory_clear(llama_get_memory(context), true)
    }

    private func tokenize(text: String, add_bos: Bool) -> [llama_token] {
        let utf8Count = text.utf8.count
        let n_tokens = utf8Count + (add_bos ? 1 : 0) + 1
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: n_tokens)
        let tokenCount = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(n_tokens), add_bos, false)

        var swiftTokens: [llama_token] = []
        for i in 0..<tokenCount {
            swiftTokens.append(tokens[Int(i)])
        }

        tokens.deallocate()

        return swiftTokens
    }

    /// - note: The result does not contain null-terminator
    private func token_to_piece(token: llama_token) -> [CChar] {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        result.initialize(repeating: Int8(0), count: 8)
        defer {
            result.deallocate()
        }
        let nTokens = llama_token_to_piece(vocab, token, result, 8, 0, false)

        if nTokens < 0 {
            let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-nTokens))
            newResult.initialize(repeating: Int8(0), count: Int(-nTokens))
            defer {
                newResult.deallocate()
            }
            let nNewTokens = llama_token_to_piece(vocab, token, newResult, -nTokens, 0, false)
            let bufferPointer = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
            return Array(bufferPointer)
        } else {
            let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nTokens))
            return Array(bufferPointer)
        }
    }
}

extension LlamaContext {

    /// 核心：流式推理 (包含 Prefill 和 Decode 两个阶段)
    /// - Parameters:
    ///   - text: 用户输入的 Prompt
    ///   - onToken: 回调闭包。返回 true 继续，返回 false 停止。
    func completion_with_callback(text: String, onToken: (_ token: String) -> Bool) {
//        guard let context = self.context, let model = self.model else {
//            print("❌ Error: Context or Model is nil")
//            return
//        }

        // 0. 获取 Vocab 指针 (新版 API 必需)
        guard let vocab = llama_model_get_vocab(model) else {
            print("❌ Error: Failed to get vocab from model")
            return
        }
        
        llama_memory_clear(llama_get_memory(context), false)

        // 1. Tokenize (转 Token ID)
        // 注意：tokenize 方法内部实现也需要确保适配新版，通常它是调用 llama_tokenize
        let tokens_list = tokenize(text: text, add_bos: true)
        let n_ctx = llama_n_ctx(context)
        
        if tokens_list.isEmpty { return }

        // --- 阶段一：Prefill (一次性处理 Prompt) ---
        
        // 初始化一个大容量 batch
        var batch = llama_batch_init(Int32(tokens_list.count), 0, 1)
        defer { llama_batch_free(batch) } // 退出作用域时自动释放

        // 手动填充 Batch (替代 common_batch_add，避免链接错误)
        for i in 0..<tokens_list.count {
            batch.token[i] = tokens_list[i]
            batch.pos[i] = Int32(i)
            batch.n_seq_id[i] = 1
            // 设置 seq_id (第 0 个序列)
            if let seq_ids = batch.seq_id[i] {
                seq_ids[0] = 0
            }
            // 只有最后一个 token 需要计算 logits 以预测下一个字
            batch.logits[i] = (i == tokens_list.count - 1) ? 1 : 0
        }
        batch.n_tokens = Int32(tokens_list.count)

        // 解码 Prompt
        if llama_decode(context, batch) != 0 {
            print("❌ Error: llama_decode failed during prefill")
            return
        }

        // --- 阶段二：Generation (逐字生成) ---
        
        var n_cur = Int32(tokens_list.count)
        let n_len = 2048 // 最大生成长度保护
        
        while n_cur < n_len && n_cur < n_ctx {
            
            let new_token_id = llama_sampler_sample(self.sampling, context, -1)

            // 1. 标准判断 (llama.cpp 认为的结束)
            if llama_vocab_is_eog(vocab, new_token_id) {
                print("✅ LlamaContext: Standard EOG detected.")
                break
            }
            
            // 2. Qwen 特殊 Token ID 硬核拦截 (可选，但推荐保留作为一层保障)
            // 这是在 Token ID 层面拦截，不会被字符串拼接问题影响
            if new_token_id == 151645 || new_token_id == 151643 { // <|im_end|> and <|endoftext|>
                print("✅ LlamaContext: Qwen special token ID detected (e.g., <|im_end|>).")
                break
            }
            
            let piece = token_to_piece2(token: new_token_id)
            
            // LlamaContext 层面不再做字符串包含判断，只负责把 token 吐出去
            // 上层 Manager 会处理拼接和字符串模式匹配
            
            // 如果上层 onToken 返回 false，则停止底层循环
            if !onToken(piece) {
                print("🛑 LlamaContext: Generation stopped by higher layer.")
                break
            }

            // D. 准备下一次迭代
            // 直接复用上面的 batch 变量，手动重置，比 llama_batch_get_one 更快更稳
            batch.n_tokens = 1
            batch.token[0] = new_token_id
            batch.pos[0] = n_cur
            batch.n_seq_id[0] = 1
            if let seq_ids = batch.seq_id[0] {
                seq_ids[0] = 0
            }
            batch.logits[0] = 1 // 必须为 true 才能进行下一次采样

            // 解码这一个 Token
            if llama_decode(context, batch) != 0 {
                print("❌ Error: llama_decode failed during generation")
                break
            }

            n_cur += 1
        }
    }

    /// 辅助函数：Token ID 转字符串 (防崩溃版)
    func token_to_piece2(token: Int32) -> String {
//        guard let model = self.model else { return "" }
        
        // 【新版 API 适配】获取 Vocab
        guard let vocab = llama_model_get_vocab(model) else { return "" }

        // 1. 越界检查 (防止 SegFault)
        let n_vocab = llama_vocab_n_tokens(vocab)
        if token < 0 || token >= n_vocab {
            return ""
        }

        // 2. 准备缓冲区 (256 字节足够容纳 UTF-8 字符)
        var buf = [CChar](repeating: 0, count: 256)

        // 3. 调用 C API (传入 vocab)
        // 参数：vocab, token, buffer, length, lstrip, special
        let n_bytes = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)

        // 4. 结果处理
        if n_bytes <= 0 { return "" }

        // 5. 安全转换
        let data = Data(bytes: &buf, count: Int(n_bytes))
        return String(data: data, encoding: .utf8) ?? ""
    }
}
