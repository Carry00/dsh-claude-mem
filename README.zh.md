# dsh-claude-mem

*中文 · [English](README.md)*

把 **DeepSeek Harness（`dsh`）** 接进
[claude-mem](https://github.com/thedotmack/claude-mem)，让它拥有持久的、跨工具共享的记忆
—— 和你 Claude Code 会话写入的是同一个记忆库。

两个方向彼此独立，只装一半也能用：

| 方向 | 作用 | 实现机制 |
|---|---|---|
| **读** —— dsh → 记忆 | agent 可以 `search` / `get_observations` 检索历史上记录过的一切（Claude Code 的 **和** dsh 的） | 把 claude-mem 的 MCP server 注册成 dsh 的 MCP client |
| **写** —— dsh → 记忆 | dsh 自己的会话被摘要成 observation，日后可检索 | 给 claude-mem 的 transcript watcher 喂一份 `session.v3.jsonl` 的 schema |

装完之后，dsh 会话和 Claude Code 会话共用一个记忆池：问 dsh「上周关于 X 我们是怎么定的」，
它能找到你在 Claude Code 里干的活，反过来也一样。

---

## 解决的痛点

**一、dsh 每开一个会话都是失忆的。** 上次踩过的坑、定过的方案、排查出的根因，新会话一概
不知道，你得重讲一遍。这不是上下文窗口不够，是会话结束就散了。

**二、记忆被工具割裂。** 你的历史积累在 claude-mem 里，但那是 Claude Code 的库；换到 dsh
就等于换了一个大脑，两边各记各的，谁也读不到谁。

**三、天真的接法接不通，而且不报错 —— 这是本仓库真正的价值所在。**
按直觉去做（让 claude-mem 的 watcher 直接盯 `~/.dsh/sessions`），你会得到一个「配置看起来
完全正确、日志一片干净、就是一条记忆都不进」的系统。这类静默失效很难自己 debug，本仓库把
它们连同成因一次性写清并给出可执行的验证：

| 你会撞上的现象 | 真正的成因 |
|---|---|
| watcher 永远收不到任何 dsh 会话 | claude-mem worker 跑在 Bun 上，其递归 `fs.watch` 不给 watch 启动后新建的目录挂 inotify；而 dsh 每个会话新建一个目录 —— 多等再久也没用 |
| watch 完全没动静，且无任何报错 | worker 启动时被监听的目录不存在，watch 静默失效且永不重试 |
| 长会话进得来，短会话一条不进 | `startAtEnd: true`，文件第一次被发现时已在末尾 |
| watcher 读不到内容 | dsh 默认把会话压成 `.jsonl.zstd` |
| dsh 每一次会话操作都抛异常 | 改成明文后，旧的 `.jsonl.zstd` 还留在 root 下 —— 一个 session root 只能有一种编码 |
| 会话目录莫名搬家 | dsh 的 patch 会**整体替换**目标行的 `config`，没重述的字段直接丢失 |
| dsh 里根本看不到 `mcp__claude_mem__*` 工具 | stdio bridge 会按 `/KEY\|PASSWORD\|SECRET\|TOKEN/i` 和 `DSH_*` 洗掉环境变量，`env` 必须显式声明；且不能照抄 `.mcp.json` 的启动器 |
| 摘要里存的是模型的思维链而不是回复 | `assistant/message` 的 `content[0]` 常是 `reasoning` 块，取值顺序错了 |
| agent 报「搜不到」 | 它会把管道坏掉如实包装成「没有结果」外加一份自信的总结 —— 必须做阳性对照 |

`scripts/verify.sh` 把上面每一条都变成一个会失败的断言，所以你不必靠猜来判断装没装对。

---

## 用 AI agent 复现

这个仓库是写给 agent 执行的。把仓库 clone 下来，对任意编码 agent（Claude Code、dsh 自己、
Codex、Cursor……）说：

> 读一下这个仓库里的 `AGENTS.md`，在本机把 dsh ↔ claude-mem 的集成装起来。

`AGENTS.md` 是面向机器的作业手册：前置检查、精确的改动、每一步的验证 gate，以及各个失败
模式及其成因。`CLAUDE.md` 是它的软链。

想手动装？看 [`docs/SETUP.md`](docs/SETUP.md)。

---

## 前置条件

- 装好 `dsh`（DeepSeek Harness）并至少跑过一次，`~/.dsh/` 已存在
- 装好 claude-mem v13.x，worker 在跑
- Linux + **systemd user 服务**（`systemctl --user`），或任意 cron 类调度器
- `node`、`bash`、`sqlite3`、`python3`

---

## 工作原理

```
                    ┌──────────────────────────────┐
   读   ────────────│  claude-mem MCP server       │◀── Claude Code 写入的同一个库
                    │  (mcp-server.cjs, stdio)     │
                    └──────────────┬───────────────┘
                                   │ mcp__claude_mem__search …
                    ┌──────────────▼───────────────┐
                    │            dsh               │
                    └──────────────┬───────────────┘
                                   │ 写 session.v3.jsonl
       ~/.dsh/sessions/<workspace>/<session-id>/session.v3.jsonl
                                   │
                                   │  静置后硬链接（timer，每 2 分钟）
                                   ▼
       ~/.dsh/sessions-cmem/<session-id>.jsonl      ← 扁平、稳定、早已存在的目录
                                   │
                    ┌──────────────▼───────────────┐
   写   ────────────│  claude-mem transcript watch │──▶ observations, platform_source='dsh'
                    └──────────────────────────────┘
```

### 为什么要多一跳硬链接

claude-mem 的 worker 跑在 **Bun** 上，而 Bun 的递归 `fs.watch` **不会**给 watch 启动之后
才新建的目录挂 inotify。dsh 每个会话开一个新目录，所以正在进行的会话对 watcher 来说是
结构性不可见的 —— 这不是多等一会儿就能赢的竞态。

解法是把**已静置**的 transcript（连续 N 秒没被写过，即会话已经停笔）发布到一个 watch 启动
时**就已经存在**的扁平目录里。那里的深度为 1 的 create 事件是可靠投递的。

用硬链接而不是拷贝：同一文件系统，不占额外磁盘；而且会话若恢复继续追加，链接同样看得到
追加内容，watcher 的字节偏移量顺势往前走即可。

代价：会话停笔到记忆可检索之间有 **2–4 分钟延迟**。这是为可靠性主动付的成本。

---

## 目录结构

```
AGENTS.md                    面向机器的作业手册（CLAUDE.md → 软链）
docs/SETUP.md                手动安装步骤
docs/TRANSCRIPT-FORMAT.md    dsh session.v3.jsonl 格式说明
docs/TROUBLESHOOTING.md      症状 → 成因 → 处置
config/dsh-mcp-client.yml    dsh patch：注册 claude-mem MCP + 会话明文化
config/transcript-watch.json claude-mem 的 dsh watcher schema
scripts/install.sh           幂等安装器
scripts/cmem-export.sh       硬链接发布脚本
scripts/verify.sh            端到端验证 gate
scripts/uninstall.sh         完整卸载
systemd/                     user service + timer
```

## 隐私

会话 transcript 里有你输入的一切，以及工具返回的一切。开启之前请先读
[`docs/PRIVACY.md`](docs/PRIVACY.md)：里面写清了哪些会被采集、哪些不会，以及怎么把某个
工作区排除掉。

## 许可证

MIT
