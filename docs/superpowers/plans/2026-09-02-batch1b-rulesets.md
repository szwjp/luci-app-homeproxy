# Batch 1b（规则集与 http_clients）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** custom 模式远程规则集改用 sing-box 1.14 `http_clients` 统一下载客户端，并支持 `initial_path` 与多 tag。

**Architecture:** 生成器在输出 `route.rule_set` 前先扫描全部启用的 remote ruleset，按“下载出站”去重生成顶级 `http_clients`；ruleset 对象输出 `http_client` tag（不再输出 `download_detour`）；`initial_path`/`extra_tags` 按 UCI 非空输出。

**Tech Stack:** ucode（generate_client.uc）、LuCI JS（client.js）。

**Spec:** `docs/superpowers/specs/2026-09-02-homeproxy1.14-singbox-1.14-features-design.md`（6.5、6.6 节）

## Global Constraints

- 只面向 sing-box ≥ 1.14，不再输出 `download_detour`。
- 无 remote ruleset 时输出与现状一致（无 `http_clients`）。
- 单 tag（无 extra_tags）时 `tag` 保持字符串 `cfg-<section>-rule`，降低 diff。
- 依赖 Batch 1a 的 fixture 运行器与“红→绿”节奏。

---

### Task B1b-1: 生成器输出 http_clients、initial_path、多 tag

**Files:**
- Modify: `root/etc/homeproxy/scripts/generate_client.uc`（custom 分支的 `/* Rule set */` 段）

**Interfaces:**
- Consumes: `uci` `ruleset` 段字段 `type`、`format`、`path`、`url`、`outbound`、`update_interval`、`initial_path`、`extra_tags`
- Produces: `config.http_clients`（数组）、`route.rule_set[]` 含 `http_client` / `initial_path` / `tag`

- [ ] **Step 1: 先写红 fixture**

Create `tests/router/fixtures/client-ruleset/config/homeproxy`：

```
config homeproxy 'config'
	option routing_mode 'custom'
	option proxy_mode 'redirect_tproxy'
	option ipv6_support '0'
	option log_level 'warn'

config homeproxy 'routing'
	option default_outbound 'direct-out'
	option default_outbound_dns 'default-dns'

config homeproxy 'dns'
	option default_server 'default-dns'

config homeproxy 'ruleset'
	option label 'geo-test'
	option enabled '1'
	option type 'remote'
	option format 'binary'
	option url 'https://example.com/{tag}.srs'
	option initial_path '/etc/homeproxy/ruleset/geo-test.srs'
	option outbound 'direct-out'
	list extra_tags 'geo-extra'
```

Create `tests/router/fixtures/client-ruleset/expect.txt`：

```
"http_clients": [
"hp-direct-out"
"http_client": "hp-direct-out"
"initial_path": "/etc/homeproxy/ruleset/geo-test.srs"
"tag": [
"cfg-geo-test-rule"
"cfg-geo-extra-rule"
```

- [ ] **Step 2: 运行确认失败**

Run: `sh tests/router/run_fixture.sh client-ruleset client`
Expected: FAIL（尚无 http_clients/initial_path/多 tag 输出）

- [ ] **Step 3: 实现**

找到 custom 分支：

```js
	/* Rule set */
	uci.foreach(uciconfig, uciruleset, (cfg) => {
		if (cfg.enabled !== '1')
			return null;

		push(config.route.rule_set, {
			type: cfg.type,
			tag: 'cfg-' + cfg['.name'] + '-rule',
			format: cfg.format,
			path: cfg.path,
			url: cfg.url,
			download_detour: get_outbound(cfg.outbound),
			update_interval: cfg.update_interval
		});
	});
```

整体替换为：

```js
	/* Rule set */
	/* sing-box 1.14: remote rule-sets download via top-level http_clients */
	const http_client_map = {};
	const http_clients = [];

	const http_tag_for = (ob) => (isEmpty(ob) ? 'default' : 'hp-' + ob);
	uci.foreach(uciconfig, uciruleset, (cfg) => {
		if (cfg.enabled !== '1' || cfg.type !== 'remote')
			return null;

		const ob = isEmpty(cfg.outbound) ? default_outbound : cfg.outbound;
		const key = ob || 'direct-out';
		if (!http_client_map[key]) {
			http_client_map[key] = true;
			push(http_clients, {
				tag: http_tag_for(key),
				dial: {
					detour: get_outbound(key)
				}
			});
		}
	});
	if (length(http_clients))
		config.http_clients = http_clients;

	uci.foreach(uciconfig, uciruleset, (cfg) => {
		if (cfg.enabled !== '1')
			return null;

		const extra_tags = cfg.extra_tags || [];
		let tag = 'cfg-' + cfg['.name'] + '-rule';
		if (length(extra_tags) && cfg.type !== 'inline') {
			tag = [tag];
			for (let t in extra_tags)
				push(tag, 'cfg-' + t + '-rule');
		}

		const ruleset = {
			type: cfg.type,
			tag: tag,
			format: cfg.format,
			path: cfg.path,
			url: cfg.url,
			update_interval: cfg.update_interval
		};
		if (cfg.type === 'remote') {
			const ob = isEmpty(cfg.outbound) ? default_outbound : cfg.outbound;
			ruleset.http_client = http_tag_for(ob || 'direct-out');
			if (!isEmpty(cfg.initial_path))
				ruleset.initial_path = cfg.initial_path;
		}
		push(config.route.rule_set, ruleset);
	});
```

说明：`default_outbound` 为 custom 分支必填（非 nil），与现有 `get_outbound` 使用一致；`http_clients` 的 dial detour 引用 `config.outbounds`/`config.endpoints` 中已存在的 tag。

- [ ] **Step 4: 运行确认通过**

Run: `sh tests/router/run_fixture.sh client-ruleset client`
Expected: PASS 且 `sing-box check` 通过（fixture 的 URL 不会被真正下载，check 只做结构校验）

- [ ] **Step 5: 提交**

```bash
git add root/etc/homeproxy/scripts/generate_client.uc tests/router
git commit -m "feat(ruleset): use http_clients, initial_path and multi-tag in 1.14"
```

---

### Task B1b-2: UI（client.js Rule Set tab）

**Files:**
- Modify: `htdocs/luci-static/resources/view/homeproxy/client.js`

**Interfaces:**
- Consumes: Task B1b-1 的 UCI 字段
- Produces: 可保存 `initial_path`、`extra_tags` 的控件；`outbound` 描述更新

- [ ] **Step 1: 在 `outbound` option 之后追加两个控件**

```js
		so = ss.taboption('ruleset', form.Value, 'initial_path', _('Initial path'),
			_('Local file with initial rule-set content; avoids blocking startup on first download (1.14).'));
		so.datatype = 'file';
		so.depends('type', 'remote');
		so.modalonly = true;

		so = ss.taboption('ruleset', form.DynamicList, 'extra_tags', _('Extra tags'),
			_('Extra rule-set tags sharing these options. Requires {tag} in path/url (1.14).'));
		so.depends('type', 'remote');
		so.modalonly = true;
```

同步给 `type` 控件在 remote+extra_tags 场景补提示：无 `{tag}` 时保存校验失败。

- [ ] **Step 2: 更新 outbound 描述并加校验**

`outbound` option 的 description 改为：`_('Outbound used to download this rule-set (via sing-box 1.14 http_clients).')`；
`url` 控件 validate 追加：当同段 `extra_tags` 非空且 URL 不含 `{tag}` 时返回错误文案。

- [ ] **Step 3: 静态检查与提交**

```bash
node --check htdocs/luci-static/resources/view/homeproxy/client.js 2>/dev/null || true
git add htdocs/luci-static/resources/view/homeproxy/client.js
git commit -m "feat(ui): rule-set initial_path, extra tags and http_client wording"
```

---

### Task B1b-3: 路由器集成验证

- [ ] **Step 1: 部署并运行**

```bash
ssh root@192.168.1.1 'cp -a /etc/homeproxy/scripts /root/hp-backup/scripts.pre-b1b'
scp root/etc/homeproxy/scripts/generate_client.uc root@192.168.1.1:/etc/homeproxy/scripts/
scp -r tests/router/fixtures/client-ruleset root@192.168.1.1:/root/hp-dev-tests/fixtures/
ssh root@192.168.1.1 'sh /root/hp-dev-tests/run_fixture.sh client-ruleset client'
```

Expected: PASS；同时重跑 `client-bypass-default` 确认无回归。

- [ ] **Step 2: 恢复生产并提交修正**

```bash
ssh root@192.168.1.1 'rm -rf /etc/homeproxy/scripts; cp -a /root/hp-backup/scripts.pre-b1b /etc/homeproxy/scripts; /etc/init.d/homeproxy restart'
git add tests/router
git commit -m "test: fix ruleset fixtures after router validation"
```

---

**Batch 1b 完成标准：** remote ruleset 输出含 http_clients/initial_path/多 tag 且通过 check；无 ruleset 或单 tag 时输出与升级前一致。
