import Foundation

public enum ResearchMarkdown {
    /// Human-readable report, explicitly not a restorable backup or investment instruction.
    public static func render(_ document: ResearchDocument) async throws -> Data {
        try await document.validate(); try Task.checkCancellation()
        let r = document.report
        var lines = ["# \(document.symbol) 本地研究", "", "> 合成 DEMO：不代表真实公司、行情或投资建议。规则未校准。", "",
            "这是研究报告，不是可恢复备份。用户自选目标独立存储，未加入本报告的冻结计算。", "",
            "- 研究 ID：\(document.id.uuidString)", "- 格式：\(document.format)",
            "- 财务截止：\(r.asOf.iso8601)", "- 计算时间：\(r.executionAt.iso8601)",
            "- 财务期末：\(r.periodEnd.iso8601)", "- 价格日期：\(r.priceDay.iso8601)",
            "- 模型：\(safe(document.model.version)) / \(r.model.contentHash)",
            "- 参数：\(safe(document.parameters.version)) / \(r.parameters.contentHash)",
            "- 映射字典：\(safe(r.dictionaryVersion))", "- 原始财务来源 SHA-256：\(document.rawHash)",
            "", "## 指标与缺失状态", "", "| 指标 | 数值或不可用原因 | 口径标记 |", "| --- | --- | --- |"]
        for key in r.metrics.keys.sorted() {
            let metric = r.metrics[key]!
            lines.append("| \(safe(key)) | \(metric.value?.decimalString ?? safe(String(describing:metric.unavailable))) | \(safe(metric.flags.joined(separator:", "))) |")
        }
        lines += ["", "## 未校准评分", "", "覆盖权重：\(document.score.coveredWeightOf84) / 84；总分：\(document.score.total?.decimalString ?? "不可用")。覆盖不是胜率。", ""]
        for key in document.score.dimensions.keys.sorted() { lines.append("- \(safe(key))：\(document.score.dimensions[key]?.value?.decimalString ?? "不可用")") }
        lines += ["", "历史区间：当前合成样本无合格历史序列，不输出参考价位。", "", "## 来源与期间", "",
            "| 字段 | 原文 | 标准值 | 单位 | 期间 | 版本 |", "| --- | --- | --- | --- | --- | --- |"]
        for fact in r.normalizedInputs {
            lines.append("| \(safe(fact.fieldID)) | \(safe(fact.sourceValue ?? "推导值")) | \(fact.value.decimalString) | \(safe(fact.unit)) | \(fact.periodStart?.iso8601 ?? "时点") → \(fact.periodEnd.iso8601) | \(safe(fact.sourceVersions.joined(separator:", "))) |")
        }
        // Full serialized input, exact source bytes, provenance and model context are
        // included for inspection. JSON strings escape embedded line breaks.
        lines += ["", "## 完整冻结输入与版本（合成证据）", "", "```json",
            String(decoding:try ResearchDocument.encoded(document),as:UTF8.self), "```", ""]
        return Data(lines.joined(separator:"\n").utf8)
    }
    private static func safe(_ text: String) -> String {
        text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;")
            .replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"|",with:"&#124;")
            .replacingOccurrences(of:"\r",with:" ").replacingOccurrences(of:"\n",with:" ")
    }
}
