import AIInsights
import AIAnalysisNetworkBroker
import SecuritySupport

/// Only closed error categories and numeric status codes may reach the UI.
/// Never stringify Error, read its description, or display remote response fields.
enum AIInsightFailureMessage {
    enum Stage { case preparingReport, validatingRequest, openingService, readingCredential, requestingAnalysis, checkingBinding }

    static let serviceUnavailable = "AI 网络服务不可用：服务缺失或校验未通过，未发送请求。请使用包含完整 AI 服务的应用版本。[AI-SERVICE]"

    static func text(for error: Error, stage: Stage) -> String {
        switch stage {
        case .preparingReport:
            switch error as? AIInsightReportAdapterError {
            case .replayMismatch:
                return "本地财报重算与保存结果不一致，未发送请求。请重新核对或生成分析报告。[AI-LOCAL-REPLAY]"
            case .missingMetric:
                return "财报摘要缺少必需的指标条目或期间结构，未发送请求；正常标记的缺失数值可以保留。[AI-LOCAL-METRICS]"
            case .invalidCutoff:
                return "财报截止时间无效，未发送请求。请重新生成分析报告。[AI-LOCAL-CUTOFF]"
            case nil:
                return "本地财报校验或摘要准备失败，未发送请求。请先重新核对财报。[AI-LOCAL-REPORT]"
            }
        case .validatingRequest:
            if error as? AIInsightError == .invalidModel {
                return "模型 ID 格式无效，未发送请求。请在 AI 设置中填写准确的模型 ID，不带空格。[AI-MODEL-FORMAT]"
            }
            if error as? AIInsightError == .budgetExceeded {
                return "财报摘要超出本地请求限制，未发送请求。[AI-INPUT-LIMIT]"
            }
            return "财报摘要的字段或来源引用未通过校验，未发送请求。[AI-INPUT]"
        case .openingService:
            return serviceUnavailable
        case .readingCredential:
            if error as? AIWorkspaceError == .missingKey {
                return "未读取到已保存的 API Key，未发送请求。请先在 AI 设置中保存自己的 OpenAI API Key。[AI-KEY-MISSING]"
            }
            if let credentialError = error as? CredentialError, case .status(let status) = credentialError {
                return "本机钥匙串读取失败（OSStatus \(status)），未发送请求。请在 AI 设置中检查凭据状态。[AI-KEYCHAIN]"
            }
            return "本机凭据读取失败，未发送请求。请在 AI 设置中检查凭据状态。[AI-KEYCHAIN]"
        case .checkingBinding:
            return "返回的解读与当前财报或请求模型不匹配，已拒绝展示。[AI-RESULT-BINDING]"
        case .requestingAnalysis:
            if let failure = error as? AIAnalysisAPIFailure { return api(failure) }
            if let failure = error as? AIAnalysisNetworkError { return network(failure) }
            if let failure = error as? AIInsightError { return response(failure) }
            return "AI 请求或返回处理失败，暂时无法进一步分类；不会自动重发。[AI-REQUEST-UNKNOWN]"
        }
    }

    private static func api(_ failure: AIAnalysisAPIFailure) -> String {
        let detail: String
        let code: String
        switch failure.reason {
        case .authentication:
            detail = "API 认证未通过。请检查 Key 是否有效、是否已撤销，以及所属项目的访问限制。"; code = "AUTH"
        case .permissionDenied:
            detail = "API 拒绝访问。请检查项目权限、模型访问权限及服务地区限制。"; code = "ACCESS"
        case .modelUnavailable:
            detail = "API 找不到该模型，或当前项目没有访问权限。请核对模型 ID 与账户权限。"; code = "MODEL"
        case .requestRejected:
            detail = "API 拒绝了请求参数。可能是模型能力或请求格式不兼容，需要检查接口配置。"; code = "REQUEST"
        case .notFound:
            detail = "API 请求的资源不存在；响应未提供可确认的模型错误类别。"; code = "NOT-FOUND"
        case .creditsExhausted:
            detail = "API 账户余额已耗尽。请检查 API 平台的余额与账单；重复点击不会补充额度。"; code = "CREDITS"
        case .organizationSpendLimit:
            detail = "已达到 API 组织支出上限。请检查组织的账单限额。"; code = "ORG-SPEND"
        case .projectSpendLimit:
            detail = "已达到 API 项目支出上限。请检查此 Key 所属项目的限额。"; code = "PROJECT-SPEND"
        case .organizationUsageLimit:
            detail = "已达到 API 组织使用量上限。请检查组织额度。"; code = "ORG-USAGE"
        case .quotaExceeded:
            detail = "API 可用额度不足。请检查账户余额及项目、组织限额。"; code = "QUOTA"
        case .rateLimited:
            detail = "API 请求受到频率限制。请稍后手动重试；不会自动重发。"; code = "RATE"
        case .rateOrQuota:
            detail = "API 返回限流或额度错误，但未提供可区分的原因。请检查账户额度与请求限制。"; code = "RATE-OR-QUOTA"
        case .serverFailure:
            detail = "OpenAI 服务暂时出错。请稍后手动重试；不会自动重发。"; code = "SERVER"
        case .unexpectedStatus:
            detail = "API 返回未支持的状态，未取得可用解读。"; code = "STATUS"
        }
        return "\(detail)（HTTP \(failure.statusCode)）[AI-HTTP-\(failure.statusCode)-\(code)]"
    }

    private static func network(_ error: AIAnalysisNetworkError) -> String {
        switch error {
        case .timedOut:
            return "等待 AI 响应超时，无法确认服务端是否已完成。已发出的请求仍可能计费；不会自动重发。[AI-TIMEOUT]"
        case .connectionFailed:
            return "无法连接 AI 服务或连接中断。请检查网络、代理与防火墙设置；不会自动重发。[AI-CONNECTION]"
        case .secureConnectionFailed:
            return "AI 服务的 HTTPS 安全连接失败。请检查系统时间与网络代理，不要关闭证书验证。[AI-TLS]"
        case .unavailable:
            return "AI 网络服务连接失败或中断，无法确认请求完成状态；不会自动重发。[AI-SERVICE-CONNECTION]"
        case .unauthorized:
            return "API 认证未通过。请检查 Key 与项目访问权限。[AI-AUTH]"
        case .rateLimited:
            return "API 请求受到频率限制，请稍后手动重试。[AI-RATE]"
        case .closed:
            return "AI 连接已关闭，未取得有效回答；已发出的请求仍可能计费。[AI-CLOSED]"
        case .busy:
            return "AI 服务仍在处理上一项请求，请等待结束后再手动操作。[AI-BUSY]"
        case .limitExceeded:
            return "本次连接已使用过，不会在同一连接重发收费请求。请手动重新发起分析。[AI-SESSION-LIMIT]"
        case .responseTooLarge:
            return "AI 返回内容超过本地接收上限，已拒绝展示。[AI-RESPONSE-SIZE]"
        case .redirectedResponse:
            return "AI 请求出现不允许的重定向，已停止处理以保护凭据。[AI-REDIRECT]"
        case .invalidRequest:
            return "AI 请求或凭据格式未通过发送前校验。请检查 Key 是否完整、是否含空格。[AI-REQUEST-VALIDATION]"
        case .invalidResponse:
            return "AI 网络服务返回了无效响应，未取得可核对内容。[AI-NETWORK-RESPONSE]"
        }
    }

    private static func response(_ error: AIInsightError) -> String {
        switch error {
        case .outputLimitReached:
            return "API 已响应，但达到本次输出 token 上限，解读未生成完整。此上限也包含推理 token；不会自动加额或重发。[AI-OUTPUT-LIMIT]"
        case .contentFiltered:
            return "API 的内容过滤中断了解读，未取得完整回答。[AI-CONTENT-FILTER]"
        case .responseFailed:
            return "API 返回分析失败状态，未生成完整回答；不会自动重发。[AI-RESPONSE-FAILED]"
        case .incompleteResponse:
            return "API 尚未返回完整解读，且没有可确认的中断原因；不会自动重发。[AI-INCOMPLETE]"
        case .refused:
            return "模型拒绝了本次解读请求，未生成分析内容。[AI-REFUSED]"
        case .invalidEvidence:
            return "AI 回答的来源引用或内容约束未通过本地校验，已拒绝展示；这不表示 Key 无效。[AI-EVIDENCE]"
        case .malformedResponse:
            return "AI 回答格式未通过本地校验，已拒绝展示；这不表示 Key 无效。[AI-FORMAT]"
        case .unexpectedOutput:
            return "AI 返回了未支持的内容结构，已拒绝展示。[AI-OUTPUT-STRUCTURE]"
        case .outputStructure(let issue):
            return outputStructure(issue)
        case .budgetExceeded:
            return "AI 请求或回答超过本地大小、嵌套或内容限制，已停止处理。[AI-CONTENT-LIMIT]"
        case .invalidInput:
            return "AI 请求数据或回答内容未通过本地校验。[AI-CONTENT-VALIDATION]"
        case .invalidModel:
            return "模型 ID 格式无效，请检查 AI 设置。[AI-MODEL-FORMAT]"
        }
    }

    private static func outputStructure(_ issue: AIInsightOutputIssue) -> String {
        switch issue {
        case .itemType:
            return "AI 返回了未启用的工具或未知输出类型，已拒绝展示。[AI-OUTPUT-ITEM]"
        case .reasoningMetadata:
            return "AI 的推理元数据格式或状态不兼容，已拒绝展示；加密推理字段本身不会阻止正常解读。[AI-OUTPUT-REASONING]"
        case .messageEnvelope:
            return "AI 的回答消息未标记为已完成的助手消息，已拒绝展示。[AI-OUTPUT-MESSAGE]"
        case .messagePhase:
            return "AI 返回了无法识别的回答阶段，未把中间说明当作最终解读。[AI-OUTPUT-PHASE]"
        case .ambiguousMessage:
            return "AI 返回了多份最终回答，无法唯一确定财报解读，已拒绝展示。[AI-OUTPUT-AMBIGUOUS]"
        case .contentBlock:
            return "AI 回答包含未支持的正文类型或无效文本结构，已拒绝展示。[AI-OUTPUT-CONTENT]"
        case .annotations:
            return "AI 回答携带额外注释或注释格式不符，未将其当作本地财报来源。[AI-OUTPUT-ANNOTATIONS]"
        case .missingText:
            return "AI 已结束响应，但没有返回最终解读正文；推理信息和中间说明不会替代正文。[AI-OUTPUT-NO-TEXT]"
        }
    }
}
