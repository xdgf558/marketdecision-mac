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
            case .referencePredatesFinancialEvidence:
                return "参考股价时刻早于财报来源截止时刻，未发送请求。请更新参考时刻，避免用后来的财报解释过去股价。[AI-REFERENCE-TIME]"
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
            // A session dependency still passes full financial validation here.
            // Preserve closed evidence diagnostics while identity mismatches stay distinct.
            if let failure = error as? AIInsightError { return response(failure) }
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
            return "本次推理与回答达到 token 上限，解读未完成；这不是 API Key 无效。可在 AI 设置查看额度，已用 token 可能计费，不会自动加额或重发。[AI-OUTPUT-LIMIT]"
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
        case .evidenceValidation(let issue, let section):
            return evidence(issue, section: section)
        case .scenarioProposal(let issue):
            return scenarioProposal(issue)
        case .malformedResponse:
            return "AI 回答格式未通过本地校验，已拒绝展示；这不表示 Key 无效。[AI-FORMAT]"
        case .formatValidation(let issue):
            return formatValidation(issue)
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

    private static func formatValidation(_ issue: AIInsightFormatIssue) -> String {
        let reason: String, code: String
        switch issue {
        case .responseJSON: reason = "API 响应不是可解析的 JSON 对象"; code = "RESPONSE-JSON"
        case .responseEnvelope: reason = "API 响应的类型或完成状态不一致"; code = "RESPONSE-STATE"
        case .responseModel: reason = "API 返回的模型标识缺失或格式不符"; code = "RESPONSE-MODEL"
        case .responseOutput: reason = "API 响应缺少有效的输出列表"; code = "RESPONSE-OUTPUT"
        case .analysisJSON: reason = "最终回答不是所要求的 JSON 对象"; code = "ANSWER-JSON"
        case .analysisFields: reason = "财报解读缺少必需部分或含额外字段"; code = "ANSWER-FIELDS"
        case .valuationFields: reason = "估值解读的口径、字段或条目数量不符"; code = "VALUATION-FIELDS"
        case .scenarioFields: reason = "三档估值假设的字段或类型不符"; code = "SCENARIO-FIELDS"
        case .sectionFields: reason = "优势、风险或限制列表的类型或数量不符"; code = "SECTION-FIELDS"
        case .claimFields: reason = "分析论点的字段不完整或含额外字段"; code = "CLAIM-FIELDS"
        case .analysisDecode: reason = "财报解读的正文或引用字段类型不符"; code = "ANSWER-TYPE"
        case .usage: reason = "API 用量统计缺失必需字段、类型不符或总数不一致"; code = "USAGE"
        }
        return "\(reason)，已拒绝展示；这不表示 Key 无效，不会自动重发。[AI-FORMAT-\(code)]"
    }

    private static func evidence(_ issue: AIInsightEvidenceIssue, section: AIInsightClaimSection) -> String {
        let location: String, sectionCode: String
        switch section {
        case .summary: location = "结论"; sectionCode = "SUMMARY"
        case .strengths: location = "优势"; sectionCode = "STRENGTHS"
        case .risks: location = "风险"; sectionCode = "RISKS"
        case .questions: location = "待核实事项"; sectionCode = "QUESTIONS"
        case .limitations: location = "解读范围"; sectionCode = "LIMITATIONS"
        case .valuationInterpretation: location = "AI 估值参考"; sectionCode = "VALUATION"
        case .valuationLimitations: location = "估值资料限制"; sectionCode = "VALUATION-LIMITATIONS"
        case .valuationAssumptions: location = "估值假设"; sectionCode = "VALUATION-ASSUMPTIONS"
        }
        let reason: String, code: String
        switch issue {
        case .emptyText: reason = "正文为空"; code = "EMPTY-TEXT"
        case .textTooLong: reason = "正文超过该部分的长度限制"; code = "TEXT-LENGTH"
        case .controlCharacter: reason = "正文含不支持的换行、制表或控制字符"; code = "TEXT-CONTROL"
        case .missingReferences: reason = "未提供来源引用"; code = "MISSING-REF"
        case .tooManyReferences: reason = "单条论点的来源引用超过 12 项"; code = "REF-COUNT"
        case .duplicateReferences: reason = "同一条论点重复引用相同来源"; code = "DUPLICATE-REF"
        case .unknownReference: reason = "引用了不在本次发送资料中的来源标识"; code = "UNKNOWN-REF"
        }
        return "AI 回答的“\(location)”\(reason)，已拒绝展示；这不表示 Key 无效，不会自动重发。[AI-EVIDENCE-\(sectionCode)-\(code)]"
    }

    private static func scenarioProposal(_ issue: AIPriceSalesScenarioIssue) -> String {
        let reason: String, code: String
        switch issue {
        case .missingProposal: reason = "未返回必需的三个情景假设"; code = "MISSING"
        case .ineligibleInput: reason = "使用了尚未满足收入和股数要求的资料"; code = "INPUT"
        case .unsupportedMethod: reason = "返回了未支持的估值方法"; code = "METHOD"
        case .invalidMultiple: reason = "目标市销率不是可表示的正十进制数"; code = "MULTIPLE"
        case .unorderedMultiples: reason = "三个目标倍数不满足保守低于中性、中性低于乐观"; code = "ORDER"
        case .missingBasisReferences: reason = "假设未引用本次 TTM 收入和实际股数"; code = "BASIS"
        }
        return "AI 估值提案\(reason)，已拒绝展示；不会自动重发或替你确认。[AI-SCENARIO-\(code)]"
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
