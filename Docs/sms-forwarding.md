# 短信转发

在「设置 → 短信转发」配置通道与规则，保存后开启总开关。首次启用、首次识别 SIM 会等待 ME/SM 同步完成并建立历史短信基线，后续新收到且已完整组装的短信进入转发队列。打开短信页面或将短信设为已读不会阻止转发。

## 通道与规则

- 飞书群机器人：Webhook、可选签名密钥、标题和正文模板；支持预览及明确标注的测试消息。
- 通用 Webhook：GET/POST/PUT/PATCH，JSON、表单或纯文本；请求头、可选签名及响应成功标记。
- vpn-manager：POST `/api/sms`，发送原始 `from`、`content` 和收信时间毫秒值。重试保持收信时间，超过三分钟停止。`submitted` 表示验证码已提交，`queued` 表示接收端已排队，登录完成需在 VPN 端确认。

规则可按模块、SIM、来源号码、正文关键词及正则组合筛选。同一条规则内条件全部满足才匹配；同一短信命中多条规则时每个通道仅入队一次。多个关键词每行一个，要求全部出现。模块与 SIM 可通过编辑页的当前设备按钮填写。

常用变量：`${from}`、`${content}`、`${org_content}`、`${timestamp}`、`${receive_time}`、`${module}`、`${module_id}`、`${sim}`、`${sim_id}`。同时兼容 `[from]` 等 Android 模板写法。JSON/表单模板使用合法 JSON 对象，占位符位于字符串值内；替换后自动转义，独立的 timestamp 值作为数字发送。

## 队列与存储

请求超时 10 秒；暂时性网络错误、HTTP 429/5xx 最多重试三次，间隔为 5、30、120 秒。应用重启后恢复未完成任务，即使此时未连接 USB 模块也会继续处理。关闭总开关会取消待发送任务；重新开启后重新建立设备短信基线。修改通道会取消其旧待发送任务，可在记录中按需手动重试。

设置和队列位于 `~/Library/Application Support/EC25 Toolbox/SMSForwarding/forwarding-v1.json`。Webhook、签名密钥和请求头只保存在 Keychain 的 `ing.fuyaoskyrocket.ec25toolbox.sms-forwarding` 服务中。发送记录不保存任意服务器响应或凭据；最近 1,000 条完成记录保留在本机，去重记录独立保留。状态文件无法读取或写入时暂停发送及设备自动清理，修复存储后重启应用。

网络发送采用至少一次语义：若服务器已收到请求、客户端尚未记录结果就退出，恢复时可能重发；普通 Webhook 接收端可按固定的短信来源、正文和 timestamp 去重。

## 验证与回滚

```sh
zsh scripts/local-audio-tests.zsh
zsh scripts/local-forwarding-archive-tests.zsh
zsh scripts/local-forwarding-core-tests.zsh
zsh scripts/local-build.zsh
zsh scripts/local-package.zsh
```

本机 CLT 测试运行方式与打包依赖见 `scripts/local-build.md`。自动化测试覆盖模拟网络、规则、签名、转义、重试、持久化恢复、历史基线及真实短信组装器。真实收信、切换 SIM 后的设备存储行为、双向语音以及 VPN 登录需实机验收。

需要暂停外发时关闭总开关。回滚应用前退出当前版本，将安装前备份的 App 恢复至 `/Applications/EC25 Toolbox.app`。转发状态独立存储，原短信归档格式不变。
