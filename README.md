# GLM Usage Menubar

macOS 原生菜单栏小组件：实时显示 GLM Coding Plan 剩余用量（5 小时 Token 窗口 + MCP 调用配额），默认每 60 秒自动刷新。单文件 Swift/AppKit 实现，零第三方依赖，无需 Xcode 工程。

## 数据源

智谱开放的（未正式写入文档的）配额查询接口，与 cc-switch、glm-plan-usage 等社区工具使用的相同，ZCode 客户端自身也调用它：

```
GET https://open.bigmodel.cn/api/monitor/usage/quota/limit
Authorization: <你的 API Key>        # 原始 Key，不带 Bearer 前缀
Accept-Language: en-US,en
```

响应关键字段：

```json
{
  "data": {
    "level": "pro",
    "limits": [
      { "type": "TOKENS_LIMIT", "percentage": 28, "nextResetTime": 1788178199891 },  // 5 小时编码窗口（已用百分比）
      { "type": "TIME_LIMIT", "usage": 1000, "currentValue": 9, "remaining": 991,    // MCP 工具调用配额
        "nextResetTime": 1790699517998, "usageDetails": [ { "modelCode": "search-prime", "usage": 6 } ] }
    ]
  }
}
```

国际版（Z.ai）将域名换成 `https://api.z.ai` 即可。

## 构建 & 运行

```bash
./build.sh            # swiftc 编译（arm64 + x86_64 通用二进制）并打包 build/GLM Usage.app
open "build/GLM Usage.app"
```

要求 macOS 13+（登录启动用了 SMAppService）。

## 安装到其他 Mac

三种方式任选：

**方式一：一键脚本（推荐）**

```bash
curl -fsSL https://raw.githubusercontent.com/spaceoi/glm-usage-menubar/main/install.sh | bash
```

自动下载最新 Release 到 /Applications（无权限则装到 ~/Applications）、清除隔离属性并启动。

**方式二：手动下载 Release**

1. 到 [Releases](https://github.com/spaceoi/glm-usage-menubar/releases/latest) 下载 `GLM-Usage-macos.zip`
2. 解压并把 `GLM Usage.app` 拖到 /Applications
3. 应用未做 Apple 公证，首次打开被 Gatekeeper 拦截时执行：
   ```bash
   xattr -cr "/Applications/GLM Usage.app"
   ```
   然后正常打开（或者右键 → 打开）。

**方式三：源码构建**

目标机器装好 Xcode Command Line Tools（`xcode-select --install`）后克隆本仓库，`./build.sh` 即可。本机编译的二进制无 Gatekeeper 问题。

**新机器上的 Key 配置**：应用按 `GLM_API_KEY` 环境变量 → `~/.glm-usage-menubar/config.json` → `~/.zcode/cli/config.json` 的顺序找 key。没有 ZCode 的机器上，点菜单栏图标 → 编辑配置…，填入 GLM Coding Plan API Key，再点一次菜单生效。

## API Key 解析顺序

1. 环境变量 `GLM_API_KEY`
2. `~/.glm-usage-menubar/config.json` 的 `apiKey`
3. `~/.zcode/cli/config.json` 里 zai-mcp-server 的 `Z_AI_API_KEY`（本机 ZCode 配置，开箱即用）

配置文件模板（菜单里点「编辑配置…」会自动创建）：

```json
{
  "apiKey": "在这里填入你的 GLM Coding Plan API Key",
  "baseUrl": "https://open.bigmodel.cn",
  "intervalSeconds": 60,
  "panelVisible": false
}
```

## 显示形式

- **菜单栏状态项（默认）**：`52% 2h47m`（窗口剩余百分比 + 距 5 小时窗口重置的紧凑倒计时，超过 24 小时为 `2d3h` 形式，≤20% 变橙、≤5% 变红），点击弹出详情：套餐等级、Token 窗口用量与重置倒计时、MCP 调用配额与按模型明细、立即刷新、编辑配置、登录时启动、退出。
- **桌面悬浮窗（可选）**：菜单里「显示悬浮窗」开启，或配置 `panelVisible: true`。毛玻璃胶囊样式，单击弹菜单，拖动移动（位置记忆在 `~/.glm-usage-menubar/state.json`）。

注意：若菜单栏已被其他状态项占满（尤其带刘海的机型），macOS 会把放不下的状态项藏进隐藏溢出区——此时需要精简菜单栏或使用 Bartender/Ice 等管理工具，或改用悬浮窗模式。

## 重置券（ZCode 账号登录）

菜单里的「🔑 登录 ZCode 账号」走 ZCode 的 OAuth CLI 流程（浏览器授权一次），之后可查询/使用**重置券**：

- `5 小时重置券: N 张（最早 yyyy-MM-dd HH:mm 到期）` / `周重置券: M 张`（周券会同步重置 5h 额度）
- `最近使用` 历史
- `⚡ 使用一张 5 小时重置券`：立即重置当前 5 小时窗口（弹确认框，消耗一张券）

说明：

- 接口为 `GET/POST /api/v1/coding-plan/reset/(status|use)`（ZCode 后端 `zcode.z.ai`），鉴权用 OAuth 换取的双令牌（`Authorization: Bearer <zcode JWT>` + `X-Bigmodel-Authorization: Bearer <MaaS token>`），纯 API Key 不被接受
- 令牌保存在 `~/.glm-usage-menubar/credentials.json`（权限 0600），与 ZCode 自身登录互不影响；过期后菜单会提示重新登录
- 所有 API 时间的显示固定为北京时间（Asia/Shanghai），与智谱网页控制台一致
- 默认网关 `https://zcode.z.ai`，可在 config.json 用 `zcodeApiBase` 覆盖

## 现成的替代方案（调研结论）

| 项目 | 形态 | 说明 |
|---|---|---|
| [glm-usage-tray](https://github.com/Everglow28/glm-usage-tray) | 跨平台托盘（dmg） | Electron 风格托盘，30/60/120s 刷新 |
| [UsageBoard](https://github.com/marsmay/UsageBoard) | 原生 macOS 菜单栏 | 插件化聚合多个服务的用量 |
| [glm-quota-monitor](https://github.com/Ngaizean/glm-quota-monitor) | macOS/Windows 桌面 | 额度管理、多账号、预警 |
| [glm-plan-usage](https://github.com/jukanntenn/glm-plan-usage) | Claude Code 插件 | CLI 内查询 |
| cc-switch（≥3.16.3） | 供应商切换器 | 内置智谱用量查询模板 |

本项目的差异点：单文件原生 Swift、无依赖、自动复用 ZCode 已配置的 Key、菜单栏+悬浮窗双形态。

## 文件结构

```
main.swift    # 全部实现（API 模型/配置/拉取/菜单栏/悬浮窗）
build.sh      # swiftc 双架构编译 + .app 打包（arm64 + x86_64）
release.sh    # 打 zip 并发布 GitHub Release（./release.sh v1.0.0）
install.sh    # 其他 Mac 一键安装最新 Release
Info.plist    # LSUIElement=true（无 Dock 图标）
```
