# Batch 0（1.14 基线加固）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 homeproxy1.14 明确以 sing-box ≥ 1.14 为运行下限，并在生成配置时提供“先校验、后原子落盘”的可靠路径。

**Architecture:** init.d 启动时解析 sing-box 版本做硬校验；两个 ucode 生成器改为写临时 JSON → `sing-box check` → 原子替换正式文件；测试基于路由器 fixture（UCI_CONFIG_DIR 隔离）与 fake sing-box wrapper。

**Tech Stack:** OpenWrt/ImmortalWrt ucode、/bin/sh rc.common、bash 测试脚本。

**Spec:** `docs/superpowers/specs/2026-09-02-homeproxy1.14-singbox-1.14-features-design.md`

## Global Constraints

- 只面向 sing-box ≥ 1.14，不保留 1.13 分支、双兼容开关或探测逻辑。
- 工作目录：`/Users/wjp/Downloads/homeproxy1.14`；路由器：`ssh root@192.168.1.1`（ImmortalWrt 25.12.1，x86_64）。
- 所有生成 JSON 最终必须通过 `sing-box check --config`。
- 真机操作前必须按 spec 9.3 备份（uci export、/etc/homeproxy、现有包）。
- 每次真机验证窗口结束后恢复生产状态（27.820.3-r3 + 原 scripts），验证期间的改动只存在于 /root/hp-dev 与备份目录。
- 提交信息用英文；代码注释英文；交流语言中文。

---

### Task 1: init.d 版本下限校验 (B0-1)

**Files:**
- Modify: `root/etc/init.d/homeproxy`（`start_service()` 开头，`config_load "$CONF"` 之后）

**Interfaces:**
- Consumes: 无
- Produces: `start_service()` 在 sing-box < 1.14 或不可探测时写日志并 `return 1`；日志行写入 `$RUN_DIR/homeproxy.log`

- [ ] **Step 1: 修改 `start_service()`，插入版本校验**

在 `config_load "$CONF"` 之后、`local routing_mode proxy_mode` 之前插入：

```sh
	local sb_ver sb_major sb_minor
	sb_ver="$(sing-box version -n 2>/dev/null)"
	if [ -z "$sb_ver" ]; then
		log "Error: cannot detect sing-box version, abort."
		return 1
	fi
	sb_major="${sb_ver%%.*}"
	sb_minor="${sb_ver#*.}"
	sb_minor="${sb_minor%%.*}"
	if [ "$sb_major" -lt 1 ] || { [ "$sb_major" -eq 1 ] && [ "$sb_minor" -lt 14 ]; }; then
		log "Error: sing-box >= 1.14.0 required, found ${sb_ver}."
		return 1
	fi
```

说明：`sing-box version -n` 输出形如 `1.14.0`；空值视为不可探测并拒绝启动，避免生成被 1.14 拒绝的配置后产生难懂错误。

- [ ] **Step 2: 语法自检**

Run: `sh -n root/etc/init.d/homeproxy`
Expected: exit 0，无输出。

- [ ] **Step 3: 提交**

```bash
git add root/etc/init.d/homeproxy
git commit -m "feat(init): require sing-box >= 1.14 at service start"
```

---

### Task 2: generate_client.uc 原子落盘 (B0-2)

**Files:**
- Modify: `root/etc/homeproxy/scripts/generate_client.uc`（文件末尾 `writefile(RUN_DIR + '/sing-box-c.json', ...)` 部分）

**Interfaces:**
- Consumes: 现有 `config` 对象、`RUN_DIR`、`system`、`writefile`
- Produces: `/var/run/homeproxy/sing-box-c.json`（仅在校验通过后出现）；校验失败时删除 `.tmp` 并 `exit(1)`

- [ ] **Step 1: 替换文件末尾**

原代码：

```js
system('mkdir -p ' + RUN_DIR);
writefile(RUN_DIR + '/sing-box-c.json', sprintf('%.J\n', removeBlankAttrs(config)));
```

替换为：

```js
system('mkdir -p ' + RUN_DIR);
const client_tmp = RUN_DIR + '/sing-box-c.json.tmp';
writefile(client_tmp, sprintf('%.J\n', removeBlankAttrs(config)));
if (system('/usr/bin/sing-box check --config ' + client_tmp) !== 0) {
	system('rm -f ' + client_tmp);
	exit(1);
}
system('mv -f ' + client_tmp + ' ' + RUN_DIR + '/sing-box-c.json');
```

- [ ] **Step 2: 语法自检**

Run: `ucode -s root/etc/homeproxy/scripts/generate_client.uc`（本地有 ucode 时）
Expected: 无语法错误；本地无 ucode 时跳过，以 B0-6 真机执行为准。

- [ ] **Step 3: 提交**

```bash
git add root/etc/homeproxy/scripts/generate_client.uc
git commit -m "feat(gen-client): validate with sing-box check before atomic replace"
```

---

### Task 3: generate_server.uc 原子落盘 (B0-3)

**Files:**
- Modify: `root/etc/homeproxy/scripts/generate_server.uc`（末尾 `writefile(RUN_DIR + '/sing-box-s.json', ...)` 部分）

**Interfaces:**
- Consumes: 现有 `config` 对象、`RUN_DIR`
- Produces: `/var/run/homeproxy/sing-box-s.json`（校验通过后原子替换）

- [ ] **Step 1: 替换文件末尾**

原代码：

```js
system('mkdir -p ' + RUN_DIR);
writefile(RUN_DIR + '/sing-box-s.json', sprintf('%.J\n', removeBlankAttrs(config)));
```

替换为：

```js
system('mkdir -p ' + RUN_DIR);
const server_tmp = RUN_DIR + '/sing-box-s.json.tmp';
writefile(server_tmp, sprintf('%.J\n', removeBlankAttrs(config)));
if (system('/usr/bin/sing-box check --config ' + server_tmp) !== 0) {
	system('rm -f ' + server_tmp);
	exit(1);
}
system('mv -f ' + server_tmp + ' ' + RUN_DIR + '/sing-box-s.json');
```

- [ ] **Step 2: 语法自检**

Run: `ucode -s root/etc/homeproxy/scripts/generate_server.uc`（本地无 ucode 时跳过）

- [ ] **Step 3: 提交**

```bash
git add root/etc/homeproxy/scripts/generate_server.uc
git commit -m "feat(gen-server): validate with sing-box check before atomic replace"
```

---

### Task 4: README 最低版本说明 (B0-4)

**Files:**
- Modify: `README`

- [ ] **Step 1: 在“构建”段之前补充运行要求**

在 `## 构建` 之前插入：

```markdown
## 运行要求

- ImmortalWrt / OpenWrt 24.10+（apk 或 opkg 均可安装）
- sing-box >= 1.14.0（ImmortalWrt 25.12 源对应 sing-box 1.14.0-r1）
- 低于 1.14 时服务会拒绝启动并记录明确日志
```

- [ ] **Step 2: 提交**

```bash
git add README
git commit -m "docs: document sing-box >= 1.14 runtime requirement"
```

---

### Task 5: 路由器测试基础设施（fixture 与 wrapper 测试）(B0-5)

**Files:**
- Create: `tests/router/run_fixture.sh`
- Create: `tests/router/fixtures/client-bypass-default/config/homeproxy`
- Create: `tests/router/fixtures/client-bypass-default/expect.txt`
- Create: `tests/router/fixtures/server-basic/config/homeproxy`
- Create: `tests/router/fixtures/server-basic/expect.txt`
- Create: `tests/router/check_version_gate.sh`

**Interfaces:**
- Consumes: 路由器上已安装本仓库最新 `generate_client.uc` / `generate_server.uc` / `homeproxy.uc`（部署方式见 B0-6）
- Produces: PASS/FAIL 汇总输出；每个 fixture 生成 JSON 并执行 `sing-box check`

- [ ] **Step 1: 写 fixture 运行器**

`tests/router/run_fixture.sh` 内容：

```bash
#!/bin/bash
# Run generator fixtures against installed scripts on the router.
# Usage: tests/router/run_fixture.sh <fixture-dir> [--server]
set -uo pipefail

FIXTURE="$1"
MODE="${2:-client}"
ROOT="$(cd "$(dirname "$0")/../.."; pwd)"
WORK="/tmp/hp-fixture"

rm -rf "$WORK"
mkdir -p "$WORK/config"
cp "$ROOT/tests/router/fixtures/$FIXTURE/config/homeproxy" "$WORK/config/homeproxy"

if [ "$MODE" = "server" ]; then
	GEN="/etc/homeproxy/scripts/generate_server.uc"
else
	GEN="/etc/homeproxy/scripts/generate_client.uc"
fi

UCI_CONFIG_DIR="$WORK/config" ucode "$GEN" >/tmp/hp-fixture.out 2>&1
RC=$?
if [ $RC -ne 0 ]; then
	echo "FAIL($FIXTURE): generator exited $RC"
	cat /tmp/hp-fixture.out
	exit 1
fi

if [ "$MODE" = "server" ]; then
	JSON="/var/run/homeproxy/sing-box-s.json"
else
	JSON="/var/run/homeproxy/sing-box-c.json"
fi

/usr/bin/sing-box check --config "$JSON" >/tmp/hp-check.out 2>&1
RC=$?
if [ $RC -ne 0 ]; then
	echo "FAIL($FIXTURE): sing-box check exited $RC"
	cat /tmp/hp-check.out
	exit 1
fi

EXPECT="$ROOT/tests/router/fixtures/$FIXTURE/expect.txt"
while IFS= read -r pat; do
	[ -z "$pat" ] && continue
	if ! grep -qF "$pat" "$JSON"; then
		echo "FAIL($FIXTURE): missing expected string: $pat"
		exit 1
	fi
done < "$EXPECT"

echo "PASS($FIXTURE)"
```

说明：`UCI_CONFIG_DIR` 指向“含 config 文件的目录”这一假设以真机第一次运行为准；若 libuci 期望目录内含 `config/` 子目录，则在执行阶段把目录结构改为 `$WORK/etc/config` 并把变量指向 `$WORK/etc`（只改本脚本，不改生成器）。

- [ ] **Step 2: 写两个 fixture**

`tests/router/fixtures/client-bypass-default/config/homeproxy`：

```
config homeproxy 'infra'
	option common_port '22,53,80,443'
	option mixed_port '5330'
	option redirect_port '5331'
	option tproxy_port '5332'
	option dns_port '5333'
	option dns_redirect '1'
	option tun_name 'singtun0'
	option tun_addr4 '172.19.0.1/30'
	option tun_addr6 'fdfe:dcba:9876::1/126'
	option tun_mtu '9000'
	option table_mark '100'
	option self_mark '100'
	option tproxy_mark '101'
	option tun_mark '102'

config homeproxy 'config'
	option main_node 'node-test'
	option main_udp_node 'same'
	option dns_server '8.8.8.8'
	option china_dns_server '223.5.5.5'
	option routing_mode 'bypass_mainland_china'
	option routing_port 'common'
	option proxy_mode 'redirect_tproxy'
	option ipv6_support '0'
	option log_level 'warn'

config node 'node-test'
	option label 'test-direct'
	option enabled '1'
	option type 'direct'
```

`expect.txt`（只校验关键结构存在，避免锁定无关细节）：

```
"tag": "dns-in"
"tag": "mixed-in"
"tag": "direct-out"
"final": "main-dns"
```

`tests/router/fixtures/server-basic/config/homeproxy`：

```
config homeproxy 'server'
	option enabled '1'
	option log_level 'warn'

config server 'test-ss'
	option label 'test-ss'
	option enabled '1'
	option type 'shadowsocks'
	option port '8388'
	option shadowsocks_encrypt_method 'aes-128-gcm'
	option password 'secret'
```

`expect.txt`：

```
"type": "shadowsocks"
"listen_port": 8388
```

- [ ] **Step 3: 版本门禁负向测试脚本**

`tests/router/check_version_gate.sh`：

```bash
#!/bin/sh
# Verify init.d refuses to start when sing-box < 1.14.
set -e

mkdir -p /tmp/sb113
cat > /tmp/sb113/sing-box <<'EOF'
#!/bin/sh
if [ "$1" = "version" ] && [ "$2" = "-n" ]; then
	echo "1.13.21"
	exit 0
fi
exec /usr/bin/sing-box "$@"
EOF
chmod +x /tmp/sb113/sing-box

set +e
PATH="/tmp/sb113:$PATH" /etc/init.d/homeproxy start >/tmp/ver-gate.out 2>&1
RC=$?
set -e

if [ $RC -eq 0 ]; then
	echo "FAIL: start succeeded with sing-box 1.13"
	exit 1
fi
grep -q "sing-box >= 1.14.0 required" /var/run/homeproxy/homeproxy.log || {
	echo "FAIL: expected version error in homeproxy.log"
	exit 1
}
echo "PASS(version-gate)"
```

- [ ] **Step 4: 本地静态检查后提交**

```bash
sh -n tests/router/run_fixture.sh tests/router/check_version_gate.sh
git add tests/router
git commit -m "test: add router fixture runner and version gate check"
```

---

### Task 6: 路由器基线验证（已授权操作）(B0-6)

**Files:** 无（路由器操作）

**前置条件：** 按 spec 9.3 完成备份；操作窗口告知用户。

- [ ] **Step 1: 备份**

```bash
ssh root@192.168.1.1 '
mkdir -p /root/hp-backup
uci export homeproxy > /root/hp-backup/homeproxy.uci.$(date +%F)
tar -cf /root/hp-backup/etc-homeproxy.$(date +%F).tar /etc/homeproxy 2>/dev/null || true
cp -a /etc/init.d/homeproxy /root/hp-backup/init.d.homeproxy.27.820.3
cp -a /etc/homeproxy/scripts /root/hp-backup/scripts.27.820.3
apk fetch sing-box=1.13.21-r1 -o /root/hp-backup || true
'
```

- [ ] **Step 2: 升级 sing-box 到 1.14.0-r1 并确认**

```bash
ssh root@192.168.1.1 'apk add sing-box; sing-box version | head -2'
```

Expected: `sing-box version 1.14.0`。

- [ ] **Step 3: 部署本仓库最新生成脚本与 init 到路由器**

```bash
cd /Users/wjp/Downloads/homeproxy1.14
scp root/etc/homeproxy/scripts/generate_client.uc root/etc/homeproxy/scripts/generate_server.uc root@192.168.1.1:/etc/homeproxy/scripts/
scp root/etc/init.d/homeproxy root@192.168.1.1:/etc/init.d/
ssh root@192.168.1.1 'chmod +x /etc/init.d/homeproxy; chmod +x /etc/homeproxy/scripts/generate_client.uc /etc/homeproxy/scripts/generate_server.uc'
```

- [ ] **Step 4: 运行 fixture 与版本门禁测试**

```bash
scp -r tests/router root@192.168.1.1:/root/hp-dev-tests
ssh root@192.168.1.1 'sh /root/hp-dev-tests/run_fixture.sh client-bypass-default client; sh /root/hp-dev-tests/run_fixture.sh server-basic server; sh /root/hp-dev-tests/check_version_gate.sh'
```

Expected: 三个 PASS（fixture 先跑一次确认 UCI_CONFIG_DIR 假设，若不成立按 B0-5 Step 1 的说明修正 run_fixture.sh 后重跑并提交修正）。

- [ ] **Step 5: 恢复生产状态并复核**

```bash
ssh root@192.168.1.1 '
cp /root/hp-backup/init.d.homeproxy.27.820.3 /etc/init.d/homeproxy
rm -rf /etc/homeproxy/scripts
cp -a /root/hp-backup/scripts.27.820.3 /etc/homeproxy/scripts
/etc/init.d/homeproxy restart
'
```

Expected: 服务按 27.820.3 脚本正常启动；`/etc/init.d/homeproxy status` 运行中。

- [ ] **Step 6: 提交可能产生的测试脚本修正**

```bash
git add tests/router
git commit -m "test: fix fixture runner after router validation"
```

---

**Batch 0 完成标准：** 代码侧具备版本下限与原子落盘；路由器上 fixture PASS、版本门禁 PASS、生产状态恢复。
