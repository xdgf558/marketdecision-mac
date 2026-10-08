# MarketDecision Mac

macOS 美股与卖方期权工作台，目前处于 **Phase 1 数据与基本面开发**。应用保留合成 DEMO 工作台，并提供独立的“离线摘录”页，可浏览固定十家公司财报摘录、保存本地研究并显式重算。另有独立“SEC 财报”页，用户填写本地联系邮箱并点击后，可请求公开申报、保留来源和缺项、保存研究并显式重算。两类研究均不提供实时行情、已获准的投资分析或交易能力。

工程与复跑说明见 [MarketDecision/README.md](MarketDecision/README.md)。Phase 0 已完成批准，Phase 1/G1 仍开放；UI 仍可迭代。SEC 导入和 IEX 参考价候选均通过独立服务显式接线。本批没有 Alpaca 账户，未验证真实行情请求、账号数据权利或真实 Keychain；参考价不会进入历史评分。

Copyright (c) 2026 xdgf558. All rights reserved.

本仓库公开可见，但不授予原项目开源许可。详见 [LICENSE](LICENSE)。依赖的独立许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，不改变原项目的权利保留。

SEC 与 IEX 联网分别由两个内嵌沙箱服务承担，主应用没有网络权限；各服务只重建自身闭合协议允许的请求。helper 的出站权限是进程级权限，代码中的主机限制不是系统域名防火墙。每页上限不等于进程内存上限，多版本规模与新页面的目标系统交互仍待验收。文件面板自动化保持未执行。
