# 笔记本服务器化部署

把家里的笔记本电脑变成一个 **Claude Code 共享记忆服务器**,其他所有设备(手机、办公本、平板)都能通过它同步 Claude Code 的会话记忆。

## 架构

```
┌─────────────────────────────────────────────┐
│  笔记本 (32GB)                              │
│                                             │
│  Docker Compose stack:                      │
│    ├─ postgres     : canonical storage      │
│    ├─ valkey       : BullMQ 队列            │
│    ├─ chroma       : 向量语义搜索           │
│    ├─ claude-mem-server : HTTP API (37877)  │
│    └─ claude-mem-worker : 生成观察数据     │
│                                             │
└─────────────────────────────────────────────┘
              ▲                  ▲
              │ Tailscale /      │
              │ Cloudflare Tunnel │
              │                  │
   ┌──────────┴───┐    ┌─────────┴───────┐
   │ 你的手机      │    │ 办公电脑         │
   │ Claude Code  │    │ Claude Code     │
   └──────────────┘    └─────────────────┘
```

## 先决条件(笔记本)

| 工具 | 验证命令 | 安装 |
|---|---|---|
| Docker Engine + Compose v2 | `docker compose version` | https://docs.docker.com/engine/install/ |
| Node.js ≥ 20 | `node --version` | https://nodejs.org |
| Bun ≥ 1.0 | `bun --version` | `npm install -g bun` |
| Git | `git --version` | 系统包管理器 |
| OpenSSL | `openssl version` | 系统包管理器 |

## 一次部署(笔记本执行)

```bash
# 1. 把这个仓库克隆到笔记本(只用一次)
git clone https://github.com/thedotmack/claude-mem.git
cd claude-mem

# 切换到你写的 feat/server-deployment 分支
git checkout feat/server-deployment

# 2. 拉取最新代码 + 启动 Docker 栈
./deploy/install.sh --pull
#   - 生成 .env(Postgres 密码随机生成)
#   - 编译插件 (npm run build + sync-marketplace)
#   - docker compose up -d (postgres + valkey + chroma + server + worker)
#   - 等待 37877/healthz 变绿

# 3. 给所有设备签发一个共享 API key
./deploy/create-api-key.sh
#   - 在 server 容器里跑 server api-key create
#   - 提取 plaintext key + projectId
#   - 保存到 deploy/.server-credentials (chmod 600)

# 4a. Tailscale 路径(推荐 — 私有,不暴露公网)
./deploy/setup-tailscale.sh
#   打印出每台设备要用的 URL + settings.json
#   每台设备安装 Tailscale App 并登录同一账号即可

# 4b. Cloudflare Tunnel 路径(任何地方都能用)
./deploy/setup-tunnel.sh --hostname mem.example.com
#   需要: 一个 Cloudflare 上的域名 + 提前 cloudflared tunnel login
#   公网 URL: https://mem.example.com
```

## 给新设备添加(每台远程设备执行一次)

```bash
# 在笔记本上生成 settings.json(假设用 Tailscale)
./deploy/client-config.sh --label alice-phone --print

# 把输出的 JSON 复制到远程设备的 ~/.claude-mem/settings.json
mkdir -p ~/.claude-mem
cat > ~/.claude-mem/settings.json <<'EOF'
{ ... 上面输出的 JSON ... }
EOF
chmod 600 ~/.claude-mem/settings.json

# 然后从源码构建并安装 claude-mem 插件本身:
git clone https://github.com/thedotmack/claude-mem.git
cd claude-mem
git checkout feat/server-deployment
npm install
npm run build
npm run sync-marketplace
```

重启 Claude Code。Hook 会通过 `runtime-selector.ts` 读取 settings.json,识别 `CLAUDE_MEM_RUNTIME=server-beta`,把观察数据 POST 到笔记本的服务器。

## 日常维护

| 操作 | 命令 |
|---|---|
| 更新到最新代码并重启 | `./deploy/install.sh --pull` |
| 查看服务器日志 | `docker compose logs -f claude-mem-server` |
| 查看 worker 日志 | `docker compose logs -f claude-mem-worker` |
| 查看 chroma 日志 | `docker compose logs -f chroma` |
| 列出 API key | `docker compose exec claude-mem-server bun /opt/claude-mem/scripts/server-beta-service.cjs server api-key list` |
| 撤销 API key | `docker compose exec claude-mem-server bun /opt/claude-mem/scripts/server-beta-service.cjs server api-key revoke <id>` |
| 重启服务器容器 | `docker compose restart claude-mem-server` |
| 重启 worker(并发数) | `docker compose up -d --scale claude-mem-worker=2` |

## 文件结构

```
deploy/
├── install.sh             # 从源码安装 + 启动 Docker 栈
├── create-api-key.sh      # 给客户端签发 API key
├── client-config.sh       # 生成远程设备的 settings.json
├── setup-tunnel.sh        # 配置 Cloudflare Tunnel
├── setup-tailscale.sh     # 配置 Tailscale 私有网络
├── .env.example           # 环境变量模板
└── README.md              # 本文件

(生成的、不提交)
├── .server-credentials    # API key + projectId + URL
└── clients/               # 每个远程设备的 settings.json
    ├── alice-phone.settings.json
    └── office-mac.settings.json
```

## 安全提醒

- `deploy/.server-credentials` 包含 **明文 API key**,已在 `.gitignore` 中。**不要提交**。
- 每个远程设备的 `~/.claude-mem/settings.json` 也包含明文 key,**不要提交**,设置 `chmod 600`。
- 如果走 Cloudflare Tunnel,密钥会在公网暴露,务必使用强 API key(已经默认 32 字节随机)。
- 强烈建议走 Tailscale 而不是公网 — 默认零攻击面。
- 撤销可疑 key:`./deploy/create-api-key.sh` 创建的新 key 时,旧的不会自动撤销,可手动 `revoke`。

## 排错

| 症状 | 原因 | 修复 |
|---|---|---|
| `install.sh` 卡在 `[5/5] waiting for server /healthz` | Postgres 启动慢 / worker 编译失败 | `docker compose logs claude-mem-server` |
| `server api-key create` 返回空 | 容器内 `bun` 不在 PATH | 脚本已用 `bun /opt/...` 显式调用,正常应该工作 |
| 客户端连不上 | URL 不对 / API key 错 / Tailscale 未登录 | 在客户端跑 `curl -fsS <URL>/healthz` 验证 |
| Chroma 启动失败 | docker image 拉不到 | `docker pull chromadb/chroma:latest` 单独验证 |
| Hook 没把数据送到服务器 | settings.json 路径错 / 字段名错 | 检查 `~/.claude-mem/settings.json` 是否完整 |

## 为什么需要 `feat/server-deployment` 分支

- `main` 分支的 `docker-compose.yml` 关闭了 Chroma(`CLAUDE_MEM_CHROMA_ENABLED=false`),向量搜索不可用。
- 这个分支:
  1. 启用了 Chroma,加了一个 `chroma` 容器。
  2. 新增 `deploy/` 目录,提供从源码一键安装 + 签发 key + 客户端配置 + 隧道配置的全套脚本。
- 笔记本运行 `git clone ... && git checkout feat/server-deployment` 后即可使用。