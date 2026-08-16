# claude-limit-relay

[English](README.md) | **简体中文** | [日本語](README.ja.md) | [한국어](README.ko.md)

本工具针对使用 Claude Code CLI 的 Claude 订阅用户，做两件事：

- **额度窗口预热** —— 用 Windows 任务计划程序在你规定的时间提前预热窗口（5 小时窗口由额度空窗期的第一条消息锚定），让你在真正开工时，可以享受横跨两个 5 小时窗口的用量
- **跨额度任务接续** —— 任务将要撞限/已经撞限 5 小时窗口额度时，在控制台排定的任务会自动站岗，在额度恢复后自动续跑，等忙完回来，一键接回接续窗口，省时省力

## 可视化控制面板

本机地址：`localhost:7878`（中/英双语，页头一键切换）

三个核心模块：额度窗口预热 / 跨额度任务排布 / 跨额度任务窗口接续

![控制台](docs/panel.zh-CN.png)

## 快速开始

**环境要求**：Windows 10/11；已安装并登录 [Claude Code CLI](https://code.claude.com/docs)；Claude 订阅用户；PowerShell 7（pwsh）；无需管理员权限

**推荐安装方式：把下面这段直接粘给 Claude Code（或其它 AI 编程工具），让它替你装好：**

```text
克隆 https://github.com/MagicYangG/claude-limit-relay 并完成安装：
1. git clone 后，在仓库目录里运行 install.ps1
2. 问我每周希望窗口重置的时刻，写进 schedule.json
   （reset 填目标重置时刻，预热时刻自动 = reset 减 5 小时）
3. 运行 ./test.ps1，确认全部用例通过
4. 运行 preheat apply，把 preheat status 的输出结果给我看
除 install.ps1 和 preheat apply 创建的内容外，不要注册或改动任何东西。
```

装完在浏览器打开 `http://localhost:7878`，用可视化控制面板操作。

**手动安装有三步**：`git clone` → `./install.ps1` → 新开终端跑 `preheat apply`。全部命令见文末[命令参考](#命令参考)。

## 注意事项

1. **需要安装 Claude Code CLI**：预热和接力都需要通过 Claude Code CLI 执行
2. **续跑窗口**：续跑是在同一目录、同一会话，原模型，原 effort，但不同的终端窗口进行的，接管注意关闭原会话窗口，防止两个窗口同时竞态写入。续跑用 `--dangerously-skip-permissions`（否则无人在场无法批准工具调用），安全含义见 [SECURITY.md](SECURITY.md)。
3. **模型专属周限降档**：Claude 订阅存在专属模型限额，在排定任务时，可以选择撞到模型周限时换 opus 跑完或停下等待

## 命令参考

推荐使用可视化控制面板。若要使用终端命令操作，可参照下文。

### 预热（preheat）

```powershell
preheat apply         # 按 schedule.json 注册每周预热任务（改表后重跑即生效）
preheat status        # 本机活动 + 排定任务 + 最近记录
preheat reset 20:00   # 一次性：让窗口在 20:00 重置（自动 15:00 预热）
preheat at 15:00      # 一次性：15:00 预热
preheat +2h           # 一次性：2 小时后预热
preheat learn         # 按最近 30 天作息给出排期建议 + 窗口利用率报告（learn auto 一键写入并生效）
preheat off           # 移除全部预热任务
```

`schedule.json` 里 `reset` 填**目标重置时刻**，预热时刻自动 = reset − 5h；`proxy` 留空表示不经代理。

### 接续（relay）

**接续命令**：走之前 `relay arm -Watch`，回来 `relay takeover`。

relay 是纯 PowerShell，不依赖任何 Claude 进程。接续执行的是 `claude --resume <原会话> -p "<续跑提示词>"` —— 挂载原对话完整历史，喂进一条真实提示词，来提示模型要做什么。

| 场景 | 命令 |
|---|---|
| 已经撞限，人在电脑前 | `relay arm`（人工确认候选会话；`-Yes` 跳过） |
| 预期会撞限但还没撞 | `relay arm -Watch`（站岗：全程零探测，靠转录判断死活） |
| 回来接管现场 | `relay takeover`（进能命中会话桶的目录 + 挂载原会话 + 拉起交互 CLI，沿用免批准模式；注意需要关闭原窗口，防止两个窗口同时写入） |

```powershell
relay arm -Prompt "先把测试跑完再收尾"       # 自定义续跑提示词
relay status                              # 队列状态 / 探测任务 / 最近记录
relay legs a3f8 5                         # 不取消排布，直接把接力上限改成 5
relay disarm                              # 取消排布（会击杀在途续跑进程）
relay doctor                              # 体检：CLI / 计划任务 / 唤醒标志 / 面板，逐项检查前置条件
relay test                                # 沙箱彩排全链路（mock claude，零额度，约 1 分钟）
relay statusline on                       # 透传接入 statusline，拿到精确重置时刻（off 还原）
```

任务能横跨几个窗口：自己干的第 1 个 + 默认 3 个 = 最多 4 个窗口（约 20 小时），`-MaxLegs N` 可调（排上之后用 `relay legs` 或面板下拉框随时改），但要注意周限。

### 卸载

```powershell
preheat off      # 移除全部预热任务
relay disarm     # 取消全部排定任务
```

然后删除 `$PROFILE` 里 `# >>> claude-limit-relay functions >>>` 到
`# <<< claude-limit-relay functions <<<` 之间几行，再删除本仓库目录。
