# Codex Provider Manager · Codex 供应商切换器

一个用 Swift / AppKit 编写的原生 macOS 工具，用来管理多个兼容 OpenAI Responses API 的服务商，并切换 Codex 的默认供应商和模型。API Key 保存在 macOS 钥匙串，无需反复手动编辑配置文件。

A native macOS utility for switching Codex model providers. Manage API endpoints and models, store API keys in macOS Keychain, and back up configuration before applying changes.

**目前仅提供 macOS 版，发布构建面向 Apple Silicon（M 系列）。** 本项目是独立社区工具，与 OpenAI 没有隶属或背书关系；不提供 API 服务、账号或额度。

## 可以做什么

- 新建、编辑、保存多个供应商资料，支持相同显示名称。
- 从当前 Codex 配置导入第三方供应商的名称、地址、模型和钥匙串引用；不导入明文 Key 或登录 Token。
- 点击按钮读取模型列表，支持下拉选择或手动输入模型 ID。
- 测试 `/models` 和 `/responses`，提示认证、接口、限流及响应格式错误。
- 应用保存的供应商，或移除顶层供应商、模型选择以恢复默认 OpenAI Provider。
- 修改前备份配置；Codex 配置校验失败时回滚，并保留其他供应商、项目、插件和 MCP 等配置。
- 切换成功后可选择让 Codex / ChatGPT 正常退出并重新打开。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | 构建目标为 macOS 11.0+；实际验证环境见 [核对记录](docs/VERIFICATION.md) |
| 芯片 | 发布包为 Apple Silicon / arm64；尚未验证 Intel Mac |
| Codex | 已安装 Codex CLI，或带有内置 Codex CLI 的 Codex / ChatGPT 桌面应用 |
| CLI 功能 | 必须支持 `model_providers.<id>.auth` 命令认证及 `codex doctor --json --summary`；旧版 CLI 可能不兼容 |
| 第三方服务 | 需要兼容 OpenAI **Responses API**；只支持 Chat Completions 的服务不能直接用于本工具 |
| 自行编译 | Xcode Command Line Tools（含 `swiftc`、macOS SDK、`codesign`）；测试及源码打包还需 `python3` |

工具会依次查找桌面应用的内置 CLI、Homebrew 常见位置及 `PATH` 中的 `codex`。找不到时会拒绝切换；也可以在启动进程的环境中设置 `CODEX_CLI_PATH`。Finder 启动的应用不一定继承终端环境变量。

## 安装与构建

如果仓库的 Releases 提供 `Codex-Provider-Manager-macOS-arm64.zip`，解压后将 `Codex Provider Manager.app` 放入「应用程序」目录。若暂未提供二进制包，可从源码编译：

```bash
# 在下载或克隆后的项目根目录执行
xcode-select --install   # 已安装命令行工具时可跳过
bash test.sh
bash build.sh
open "dist/Codex Provider Manager.app"
```

无需安装第三方 Swift 依赖，也不需要单独的 Xcode 工程。构建结果位于 `dist/`。

当前构建使用 ad-hoc 本机签名，**未做 Developer ID 签名或 Apple 公证**。从网上下载的包可能被 Gatekeeper 拦截；确认来源后按 macOS 的「隐私与安全性」提示操作，或自行编译。不要全局关闭 Gatekeeper。

## 使用方法

1. 点击「新建」，填写供应商名称、API Base URL 和该服务支持的模型 ID。
2. 填写 API Key；可点击「读取模型」或「测试 models」获取列表，也可手动填写模型。
3. 点击「保存」。Key 会写入当前用户钥匙串，输入框随后清空；清空不代表 Key 被删除。
4. 按需点击「测试 responses」，确认后发送一条简短生成请求。这可能产生服务商费用。
5. 点击「应用供应商」并确认。程序备份配置、写入新设置，再用 Codex CLI 校验配置；失败时尝试恢复原状态。
6. 切换成功后重启对应客户端，并开启新会话验证实际调用。已有会话可能仍使用旧的模型或供应商。

修改表单后需要先保存再应用。模型列表成功只说明 `/models` 可用；Responses 测试成功也不代表工具调用、流式传输、长上下文等全部功能都兼容。

### Base URL 怎么填写

填写 **API 根地址**，不要带具体接口名称。测试与写入配置使用相同的规则：

| 输入 | 实际 API 根地址 | 模型测试地址 |
| --- | --- | --- |
| `https://api.example.com` | `https://api.example.com/v1` | `https://api.example.com/v1/models` |
| `https://api.example.com/v1/` | `https://api.example.com/v1` | `https://api.example.com/v1/models` |
| `https://api.example.com/gateway/api` | `https://api.example.com/gateway/api` | `https://api.example.com/gateway/api/models` |
| `http://127.0.0.1:8080/v1` | 保留本机地址 | `http://127.0.0.1:8080/v1/models` |

自定义路径按服务商要求填写，不会自动追加 `/v1`。地址不得包含用户名、密码、查询参数或片段；除本机地址外只允许 HTTPS。以上均为示例，不是预置服务。

### 恢复默认供应商

点击「官方恢复」会移除用户配置顶层的 `model_provider` 和 `model`，保留供应商定义及其他设置，让 Codex 使用默认 OpenAI Provider 和默认模型选择。

这不是恢复某次备份，也不会替你登录 ChatGPT、切换认证方式或清除其他代理设置。最终认证方式取决于 Codex 已有登录状态和环境设置。程序不读取或修改 `auth.json`。

### 修改哪些文件

默认读写 `~/.codex/config.toml`；启动进程设置 `CODEX_HOME` 时改用该目录。备份保存在配置文件同目录下的 `backups/provider-switcher/`，每份备份有唯一文件名。供应商资料在 `~/Library/Application Support/Codex Provider Manager/profiles.json`；这份 JSON 不含 Key。

程序写入的供应商配置类似下面这样，Key 由固定的钥匙串查询命令提供：

```toml
model = "your-model-id"
model_provider = "cpm-example-uniqueid"

[model_providers.cpm-example-uniqueid]
name = "Example Provider"
base_url = "https://api.example.com/v1"
wire_api = "responses"

[model_providers.cpm-example-uniqueid.auth]
command = "/usr/bin/security"
args = ["find-generic-password", "-a", "example-account-id", "-s", "com.local.codex-provider-manager.api-key", "-w"]
```

这是格式示例，不含可用凭据。命令认证不与 `env_key`、`experimental_bearer_token` 或 `requires_openai_auth` 混用。配置字段依据 [OpenAI 官方配置参考](https://learn.chatgpt.com/docs/config-file/config-reference) 和 [自定义模型供应商说明](https://learn.chatgpt.com/docs/config-file/config-advanced) 核对。

## 安全与使用边界

- 无默认供应商或内置 Key；输入 Key 后不会自动发起请求。点击测试时，Key 会发送到你填写的服务地址。
- 钥匙串条目允许 `/usr/bin/security` 读取，因此不能防止同一 macOS 用户下的其他进程通过该命令读取。完整说明见 [SECURITY.md](SECURITY.md)。
- 删除资料或更换 Key 会保留旧钥匙串条目，避免影响已生效的配置。确认不再引用后，可在「钥匙串访问」中手动清理。
- 配置编辑器只修改供应商选择、模型选择及同 ID 的供应商表，不会重新格式化整个 TOML。顶层存在命名 `profile` 或内联 / 点式供应商定义时拒绝修改，避免覆盖优先级和结构冲突。
- CLI 的 `--profile`、`-c` 参数、环境变量或管理员策略可能覆盖默认配置，本工具不管理这些覆盖项。
- 符号链接形式的配置文件不支持；请自行管理这类配置。操作期间避免其他程序同时编辑配置文件。
- 网络测试收到超过 1 MiB 的响应时拒绝解析；这不是下载过程中的流量或内存上限。
- 未完成所有 macOS 版本、Intel 架构和第三方服务商的实机验证。当前测试范围及限制见 [核对记录](docs/VERIFICATION.md)。

## 开发与打包

```bash
bash test.sh       # 本机架构编译并运行隔离测试
bash build.sh      # 生成 arm64 macOS 应用并验证 ad-hoc 签名
bash release.sh    # 先测试、构建，再生成应用包、源码包和 SHA-256 校验文件
```

测试使用临时目录、独立的临时钥匙串及模拟 HTTP 响应，不读取个人 API Key，不修改真实 Codex 配置，也不执行付费请求。安装了兼容 CLI 时会额外校验生成配置；未安装时明确输出 `SKIP`。

```text
Sources/      Swift / AppKit 源码
Resources/    应用 Info.plist
Tests/        配置、回滚、钥匙串、网络等隔离测试
scripts/      仅打包指定源码文件的脚本
docs/        程序核对记录
```

源码仓库只应包含代码、测试和文档；生成的 `.app`、压缩包、真实配置和个人资料均被 `.gitignore` 排除。发布包应通过 `release.sh` 重新生成，再上传到 GitHub Releases。

## 许可证

[MIT](LICENSE)。欢迎提交问题和改进；反馈时请移除 API Key、Token、私人服务地址和个人路径。
