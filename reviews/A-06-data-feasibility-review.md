# A-06 数据可行性规划：公开审查摘要

日期：2026-09-09。状态：待审；本次只公开精简摘要。

## 审查与批准边界

本 PR 供审查摘要准确性及是否合并。进入审查或合并不批准 DF-01 至 DF-05，不选择供应商或 DATA-000 A/B/C，不授权采购、A-07或应用开发，也不锁定 A-04 参数或 A-05 DC/CT。
完整规格、数据需求矩阵、证据登记、验证计划、任务与记忆仅保留本地；具体决策以本地完整审查材料为准。

## 待审规划建议

| ID | 精简建议 | 状态 |
|---|---|---|
| DF-01 | 早期行情、账本EOD、当前期权链与历史研究分别验证；来源、时效、质量、用途资格保持可区分 | PENDING_REVIEW |
| DF-02 | 后续核查至少三家历史供应商；Massive Quotes权限、Cboe快照与Alpaca短窗口各有独立证据，不视为已选源 | PENDING_REVIEW |
| DF-03 | 核对本地保存、离线重算、普通备份恢复、导出展示及订阅终止后的保留权，不只核对下载权限 | PENDING_REVIEW |
| DF-04 | 单列公开数据延迟及历史发布证据缺口，不自动删除分项、重配评分或代填阈值 | PENDING_REVIEW |
| DF-05 | 区分成功、失败、受阻和未测；资料比较不构成数据合格或模型校准资格 | PENDING_REVIEW |

## 官方资料核查摘要

以下反映本次2026-09-09资料核查，未验证认证账户权限，执行前须重新核验产品和许可版本。
- [Massive](https://massive.com/options) 套餐页的5+年表述不证明某账户取得十年Quotes；原先历史起点主张仍需按Quotes产品核对。
- [Alpaca](https://docs.alpaca.markets/us/docs/historical-option-data) 历史期权起于2024-02，不能单独覆盖指定压力期；indicative不是真实OPRA报价。
- [Cboe DataShop](https://datashop.cboe.com/option-quote-intervals) 的2012起点与NBBO间隔快照提供候选；不证明tick全流、退市覆盖、OCC完整或许可合格。报价size规则变化、半日市交付与报价时间差也需核验。
- [NAAIM](https://naaim.org/programs/naaim-exposure-index/) 公开页说明三个月延迟，不能当作本周最新读数。
- [FRED](https://fred.stlouisfed.org/docs/api/fred/realtime_period.html) 日期vintage不自动证明日内可得时刻；[CFTC](https://www.cftc.gov/MarketReports/CommitmentsofTraders/index.htm) 一般发布规律及有限历史发布日期不能替代逐条历史证据。

## 保留的数据与阶段门槛

历史最低要求仍为至少十年且覆盖2018-02、2020-03、2022；NBBO bid/ask而非仅last/settlement；退市历史或明确缺口范围；OCC调整记录；允许本地分析的许可。明确缺口不等于无幸存者偏差。
至少三家须分别留下后续实测记录；无权限记未测/受阻，不把桌面比较冒充实测。没有供应商获QUALIFIED。
账本EOD不依赖十年历史采购；Mid/Last+STALE不能转作历史成交代理；延迟、陈旧或indicative不得冒充实时。
Phase 3首次期权采集即需日摘要结构；市场状态须有历史快照；日历覆盖、事件版本、公司行动与恢复引用完整性继续按本地要求验证。
DATA-000仍UNSELECTED，不阻塞Phase 1–4及Phase 5独立工作；G5仍须有结论。未满足且未选降级时Phase 6为BLOCKED_BY_DATA。
B不默认完整回测页，移除Brier/Isotonic/时间三分割并标窗口限制；C延期Phase 6，仅风险中性概率，不开放Bootstrap。A/B也须独立通过匹配、校准和重采样契约验收。
Phase 7核心独立，延期不等于通过；扫描器不承诺依赖未来数据积累的上线日期。提醒48/64容量、去重/检查连续性与备份恢复仍待实测。

## 验证范围

本地完成14组官方证据、15类需求、三家比较及14项验证设计；14项均未执行。未调用认证行情接口、采购或联系供应商。
本地文档引用与基线完整性检查通过，不是供应商实测、金融测试或CI；检查材料未公开，不能从本PR独立复跑。
本PR仅新增本文件，无应用代码、密钥、真实交易数据或完整私人资料；不开启自动合并。
