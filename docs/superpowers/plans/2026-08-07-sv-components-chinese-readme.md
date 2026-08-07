# SystemVerilog `.sv`、标准 UVM 组件与中文 README 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将仓库自有 `.svh` 全部迁移为 package include 的 `.sv`，把完成处理重构为标准 `gq_monitor`，并将主 README 全文改为中文。

**Architecture:** 保留 `gq_queue_engine` 作为每队列共享状态核心，主动 `gq_queue_agent` 创建 sequencer、driver、monitor 和 engine。monitor 创建并拥有 completion analysis port，engine 只保存该 port 的非 owning handle并执行有序完成退休；driver 继续处理 TX submit 与 RX 首次启动。

**Tech Stack:** SystemVerilog、UVM 1.2、Synopsys VCS W-2024.09-SP1、GNU Make、Bash、host_mem submodule。

---

## 前置状态

- Worktree：`/home/ryan/workspace/ryan/fifo_work/.worktrees/sv-components-chinese-readme`
- Branch：`feature/sv-components-chinese-readme`
- 设计提交：`15381e1 docs: design sv component migration`
- 设计规格：`docs/superpowers/specs/2026-08-07-sv-components-chinese-readme-design.md`
- 未修改基线已经在 `10.11.10.53` 通过七项 VCS 测试；每项 exit 0、最终 W/E/F 为 `0/0/0`、全部 HOST_MEM leak 为 0。

## 文件结构

- `src/gq/gq_pkg.sv`：通用队列 package 编译入口，按依赖顺序 include 通用 `.sv` class 文件。
- `src/gq/gq_agent.sv`：定义 sequencer、driver、monitor 和主动 queue agent。
- `src/gq/gq_queue_engine.sv`：队列状态、内存、submit、completion、refill、reset 和 cleanup；保存 monitor port 的非 owning handle。
- `src/gq/gq_env.sv`：创建 sparse agents，并提供 `get_monitor(key)`。
- `src/mailbox/mailbox_pkg.sv`：mailbox package 编译入口，include mailbox `.sv` class 文件。
- `tb/gq_test_pkg.sv`：测试 package 编译入口，include mocks/tests `.sv` 文件。
- `tb/tests/gq_agent_test.sv`：标准 agent 层次与 monitor analysis 数据路径的 focused test。
- `scripts/check_sv_layout.sh`：静态验证仓库自有 source/test 文件全部为 `.sv`。
- `README.md`：中文使用说明与 scoreboard 连接示例。

---

### Task 1: 先建立 `.sv` 布局的失败检查

**Files:**
- Create: `scripts/check_sv_layout.sh`
- Modify: `Makefile`

- [ ] **Step 1: 创建结构检查脚本**

使用 `apply_patch` 创建以下完整脚本：

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

status=0

mapfile -t stale_files < <(
    find src tb/mocks tb/tests -type f -name '*.svh' -print | sort
)
if ((${#stale_files[@]} != 0)); then
    printf 'repository-owned .svh files remain:\n' >&2
    printf '  %s\n' "${stale_files[@]}" >&2
    status=1
fi

mapfile -t stale_includes < <(
    rg -n '`include "[^"]+\.svh"' \
        src/gq/gq_pkg.sv src/mailbox/mailbox_pkg.sv tb/gq_test_pkg.sv \
        | rg -v 'uvm_macros\.svh' || true
)
if ((${#stale_includes[@]} != 0)); then
    printf 'repository-owned .svh includes remain:\n' >&2
    printf '  %s\n' "${stale_includes[@]}" >&2
    status=1
fi

mapfile -t stale_guards < <(
    rg -n '^`(ifndef|define) [A-Z0-9_]+_SVH$' src tb/mocks tb/tests \
        || true
)
if ((${#stale_guards[@]} != 0)); then
    printf 'SVH include guards remain:\n' >&2
    printf '  %s\n' "${stale_guards[@]}" >&2
    status=1
fi

exit "$status"
```

执行：

```bash
chmod 755 scripts/check_sv_layout.sh
```

- [ ] **Step 2: 在 Makefile 中加入检查目标**

把 `.PHONY: build vcs run` 改为：

```make
.PHONY: build vcs run check-layout
```

并在 `run` 目标之前加入：

```make
check-layout:
	./scripts/check_sv_layout.sh
```

- [ ] **Step 3: 运行 RED，证明检查能抓住现状**

Run：

```bash
make check-layout
```

Expected：exit 非 0，输出 `repository-owned .svh files remain`，并列出当前 31 个 `.svh`；不得因为脚本语法错误失败。

- [ ] **Step 4: 检查脚本语法**

```bash
bash -n scripts/check_sv_layout.sh
git diff --check
```

Expected：两条命令均 exit 0。此时不提交；Task 2 将使检查变绿后一起提交。

---

### Task 2: 将 31 个自有 `.svh` 迁移为 `.sv`

**Files:**
- Rename: `src/gq/*.svh` → `src/gq/*.sv`
- Rename: `src/mailbox/*.svh` → `src/mailbox/*.sv`
- Rename: `tb/mocks/*.svh` → `tb/mocks/*.sv`
- Rename: `tb/tests/*.svh` → `tb/tests/*.sv`
- Modify: `src/gq/gq_pkg.sv`
- Modify: `src/mailbox/mailbox_pkg.sv`
- Modify: `tb/gq_test_pkg.sv`
- Modify: `docs/superpowers/plans/2026-08-04-generic-queue-uvm-env.md`
- Modify: `docs/superpowers/plans/2026-08-06-lock-free-publish-lifecycle.md`
- Modify: `docs/superpowers/specs/2026-08-06-publish-lifecycle-fix-design.md`
- Test: `scripts/check_sv_layout.sh`

- [ ] **Step 1: 使用 `git mv` 执行精确重命名**

```bash
git mv src/gq/gq_agent.svh src/gq/gq_agent.sv
git mv src/gq/gq_completion_source.svh src/gq/gq_completion_source.sv
git mv src/gq/gq_desc_base.svh src/gq/gq_desc_base.sv
git mv src/gq/gq_env.svh src/gq/gq_env.sv
git mv src/gq/gq_env_cfg.svh src/gq/gq_env_cfg.sv
git mv src/gq/gq_hw_adapter.svh src/gq/gq_hw_adapter.sv
git mv src/gq/gq_ptr_codec.svh src/gq/gq_ptr_codec.sv
git mv src/gq/gq_queue_cfg.svh src/gq/gq_queue_cfg.sv
git mv src/gq/gq_queue_engine.svh src/gq/gq_queue_engine.sv
git mv src/gq/gq_refill_profile.svh src/gq/gq_refill_profile.sv
git mv src/gq/gq_request.svh src/gq/gq_request.sv
git mv src/gq/gq_reset_controller.svh src/gq/gq_reset_controller.sv
git mv src/gq/gq_tail_mem_completion.svh src/gq/gq_tail_mem_completion.sv
git mv src/gq/gq_types.svh src/gq/gq_types.sv
git mv src/gq/gq_wait_policy.svh src/gq/gq_wait_policy.sv

git mv src/mailbox/mailbox_completion.svh src/mailbox/mailbox_completion.sv
git mv src/mailbox/mailbox_env.svh src/mailbox/mailbox_env.sv
git mv src/mailbox/mailbox_refill_profile.svh src/mailbox/mailbox_refill_profile.sv
git mv src/mailbox/mailbox_rx_desc.svh src/mailbox/mailbox_rx_desc.sv
git mv src/mailbox/mailbox_sequences.svh src/mailbox/mailbox_sequences.sv
git mv src/mailbox/mailbox_tx_desc.svh src/mailbox/mailbox_tx_desc.sv

git mv tb/mocks/gq_test_ptr_codec.svh tb/mocks/gq_test_ptr_codec.sv
git mv tb/mocks/mailbox_mock_adapter.svh tb/mocks/mailbox_mock_adapter.sv
git mv tb/mocks/mailbox_mock_dut.svh tb/mocks/mailbox_mock_dut.sv

git mv tb/tests/gq_completion_test.svh tb/tests/gq_completion_test.sv
git mv tb/tests/gq_config_test.svh tb/tests/gq_config_test.sv
git mv tb/tests/gq_refill_test.svh tb/tests/gq_refill_test.sv
git mv tb/tests/gq_regression_test.svh tb/tests/gq_regression_test.sv
git mv tb/tests/gq_reset_test.svh tb/tests/gq_reset_test.sv
git mv tb/tests/gq_submit_test.svh tb/tests/gq_submit_test.sv
git mv tb/tests/mailbox_desc_test.svh tb/tests/mailbox_desc_test.sv
```

Expected：`git status --short` 显示 31 个 rename，不出现内容丢失。

- [ ] **Step 2: 更新 include guard**

这是纯机械替换，只对刚重命名的 31 个文件执行：

```bash
find src/gq src/mailbox tb/mocks tb/tests -type f -name '*.sv' -print0 \
    | xargs -0 perl -pi -e 's/_SVH\b/_SV/g'
```

验证：

```bash
rg -n '^`(ifndef|define) [A-Z0-9_]+_SVH$' src tb/mocks tb/tests
```

Expected：无输出、exit 1（没有匹配），不是文件读取错误。

- [ ] **Step 3: 用 `apply_patch` 更新三个 package include 列表**

`src/gq/gq_pkg.sv` 的仓库自有 include 必须精确变为：

```systemverilog
    `include "gq_types.sv"
    `include "gq_desc_base.sv"
    `include "gq_refill_profile.sv"
    `include "gq_request.sv"
    `include "gq_ptr_codec.sv"
    `include "gq_hw_adapter.sv"
    `include "gq_completion_source.sv"
    `include "gq_tail_mem_completion.sv"
    `include "gq_queue_cfg.sv"
    `include "gq_wait_policy.sv"
    `include "gq_env_cfg.sv"
    `include "gq_queue_engine.sv"
    `include "gq_reset_controller.sv"
    `include "gq_agent.sv"
    `include "gq_env.sv"
```

`src/mailbox/mailbox_pkg.sv` 必须精确变为：

```systemverilog
    `include "mailbox_tx_desc.sv"
    `include "mailbox_rx_desc.sv"
    `include "mailbox_completion.sv"
    `include "mailbox_refill_profile.sv"
    `include "mailbox_sequences.sv"
    `include "mailbox_env.sv"
```

`tb/gq_test_pkg.sv` 的 mocks/tests include 必须精确变为：

```systemverilog
    `include "host_mem_manager.sv"
    `include "mocks/gq_test_ptr_codec.sv"
    `include "mocks/mailbox_mock_adapter.sv"
    `include "mocks/mailbox_mock_dut.sv"
    `include "tests/gq_config_test.sv"
    `include "tests/mailbox_desc_test.sv"
    `include "tests/gq_submit_test.sv"
    `include "tests/gq_completion_test.sv"
    `include "tests/gq_refill_test.sv"
    `include "tests/gq_reset_test.sv"
    `include "tests/gq_regression_test.sv"
```

`uvm_macros.svh` 必须保持不变。

- [ ] **Step 4: 同步历史文档中的 31 个自有文件名**

使用以下 stem 列表做精确替换，不得全局替换所有 `.svh`：

```bash
stems=(
  gq_agent gq_completion_source gq_desc_base gq_env gq_env_cfg
  gq_hw_adapter gq_ptr_codec gq_queue_cfg gq_queue_engine
  gq_refill_profile gq_request gq_reset_controller
  gq_tail_mem_completion gq_types gq_wait_policy
  mailbox_completion mailbox_env mailbox_refill_profile mailbox_rx_desc
  mailbox_sequences mailbox_tx_desc gq_test_ptr_codec mailbox_mock_adapter
  mailbox_mock_dut gq_completion_test gq_config_test gq_refill_test
  gq_regression_test gq_reset_test gq_submit_test mailbox_desc_test
)
for stem in "${stems[@]}"; do
  perl -pi -e "s/\\Q${stem}.svh\\E/${stem}.sv/g" \
    docs/superpowers/plans/2026-08-04-generic-queue-uvm-env.md \
    docs/superpowers/plans/2026-08-06-lock-free-publish-lifecycle.md \
    docs/superpowers/specs/2026-08-06-publish-lifecycle-fix-design.md
done
```

验证 `uvm_macros.svh` 仍使用原扩展名：

```bash
rg -n 'uvm_macros\.svh' src tb docs
```

- [ ] **Step 5: 运行 GREEN 布局检查和 package dry-run**

```bash
make check-layout
make -n run TEST=gq_config_test
git diff --check
```

Expected：全部 exit 0；VCS `SOURCES` 仍只有 package/top `.sv` 入口。

- [ ] **Step 6: 在 53 上运行编译型 GREEN**

```bash
scripts/run_vcs_remote.sh gq_config_test
scripts/run_vcs_remote.sh mailbox_desc_test
```

Expected：每项 exit 0、最终 W/E/F=`0/0/0`，HOST_MEM 全部为 0。

- [ ] **Step 7: 提交扩展名迁移**

```bash
git add Makefile scripts/check_sv_layout.sh src tb docs/superpowers
git diff --cached --check
git commit -m "refactor: migrate included sources to sv"
```

---

### Task 3: 先添加标准 agent/monitor 的失败测试

**Files:**
- Create: `tb/tests/gq_agent_test.sv`
- Modify: `tb/gq_test_pkg.sv`

- [ ] **Step 1: 创建 focused collector、counting memory 和 agent test**

使用 `apply_patch` 创建 `tb/tests/gq_agent_test.sv`，内容如下：

```systemverilog
`ifndef GQ_AGENT_TEST_SV
`define GQ_AGENT_TEST_SV

class gq_agent_counting_mem extends host_mem_manager;
    `uvm_object_utils(gq_agent_counting_mem)

    function new(string name = "gq_agent_counting_mem");
        super.new(name);
    endfunction

    function int unsigned outstanding_blocks();
        return alloc_count;
    endfunction
endclass

class gq_agent_completion_collector extends uvm_component;
    `uvm_component_utils(gq_agent_completion_collector)

    uvm_analysis_imp #(gq_desc_base, gq_agent_completion_collector)
        analysis_export;
    host_mem_api mem;
    int unsigned completion_count;
    int unsigned owned_memory_observations;

    function new(string name = "gq_agent_completion_collector",
                 uvm_component parent = null);
        super.new(name, parent);
        analysis_export = new("analysis_export", this);
        mem = null;
        completion_count = 0;
        owned_memory_observations = 0;
    endfunction

    function void write(gq_desc_base desc);
        mailbox_tx_desc tx;
        byte observed[];

        if (!$cast(tx, desc))
            `uvm_fatal("AGENT_MONITOR_TYPE",
                       "monitor published a non-mailbox TX descriptor")
        completion_count++;
        if (tx.buf_len != 0) begin
            mem.read_mem(tx.buf_addr, tx.buf_len, observed,
                         `__FILE__, `__LINE__);
            if (observed.size() == tx.buf_len)
                owned_memory_observations++;
        end
    endfunction
endclass

class gq_agent_test extends uvm_test;
    `uvm_component_utils(gq_agent_test)

    gq_agent_counting_mem mem;
    gq_test_ptr_codec codec;
    mailbox_mock_adapter adapter;
    mailbox_mock_dut dut;
    mailbox_env_cfg cfg;
    gq_queue_cfg irq_cfg;
    mailbox_env env;
    gq_agent_completion_collector collector;

    function new(string name = "gq_agent_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        string reason;

        super.build_phase(phase);
        mem = new("mem");
        mem.init_region(64'h0000_0001_7200_0000,
                        64'h0000_0001_72ff_ffff, MODE_LINEAR, 16);
        codec = gq_test_ptr_codec::type_id::create("codec");
        adapter = mailbox_mock_adapter::type_id::create("adapter");
        dut = mailbox_mock_dut::type_id::create("dut");
        dut.mem = mem;
        dut.adapter = adapter;

        cfg = mailbox_env_cfg::type_id::create("cfg");
        cfg.mem = mem;
        cfg.adapter = adapter;
        cfg.ptr_codec = codec;
        if (!cfg.add_tx(12, 32, reason))
            `uvm_fatal("AGENT_CFG", reason)

        irq_cfg = gq_queue_cfg::type_id::create("irq_cfg");
        irq_cfg.queue_id           = 13;
        irq_cfg.role               = GQ_TX;
        irq_cfg.depth              = 32;
        irq_cfg.desc_size          = 64;
        irq_cfg.alignment          = 64;
        irq_cfg.status_area_size   = 0;
        irq_cfg.wait_mode          = GQ_IRQ;
        irq_cfg.poll_interval      = 10ns;
        irq_cfg.completion_timeout = 1us;
        irq_cfg.ptr_codec          = codec;
        irq_cfg.completion_source  = mailbox_completion::type_id::create(
            "irq_completion");
        if (!cfg.add_queue(irq_cfg, reason))
            `uvm_fatal("AGENT_CFG", reason)

        uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", cfg);
        env = mailbox_env::type_id::create("env", this);

        collector = gq_agent_completion_collector::type_id::create(
            "collector", this);
        collector.mem = mem;
    endfunction

    function void connect_phase(uvm_phase phase);
        gq_monitor poll_monitor;
        gq_monitor irq_monitor;

        super.connect_phase(phase);
        poll_monitor = env.get_monitor("tx_12");
        irq_monitor = env.get_monitor("tx_13");
        if (poll_monitor == null)
            `uvm_fatal("AGENT_MONITOR_PATH", "tx_12 monitor was not created")
        if (irq_monitor == null)
            `uvm_fatal("AGENT_MONITOR_PATH", "tx_13 monitor was not created")
        poll_monitor.completion_ap.connect(collector.analysis_export);
        irq_monitor.completion_ap.connect(collector.analysis_export);
    endfunction

    function gq_queue_engine find_engine(string key);
        uvm_component component_handle;
        gq_queue_engine engine;

        component_handle = uvm_root::get().find(
            {"uvm_test_top.env.", key, ".engine"});
        if (!$cast(engine, component_handle))
            `uvm_fatal("AGENT_ENGINE_PATH", {key, " engine was not created"})
        return engine;
    endfunction

    function gq_sequencer find_sequencer(string key);
        uvm_component component_handle;
        gq_sequencer sequencer;

        component_handle = uvm_root::get().find(
            {"uvm_test_top.env.", key, ".sequencer"});
        if (!$cast(sequencer, component_handle))
            `uvm_fatal("AGENT_SEQUENCER_PATH",
                       {key, " sequencer was not created"})
        return sequencer;
    endfunction

    function void check_component_tree(string key);
        uvm_component component_handle;
        gq_driver driver;
        gq_monitor monitor;

        component_handle = uvm_root::get().find(
            {"uvm_test_top.env.", key, ".driver"});
        if (!$cast(driver, component_handle))
            `uvm_fatal("AGENT_DRIVER_PATH", {key, " driver was not created"})
        component_handle = uvm_root::get().find(
            {"uvm_test_top.env.", key, ".monitor"});
        if (!$cast(monitor, component_handle))
            `uvm_fatal("AGENT_MONITOR_PATH", {key, " monitor was not created"})
        if (uvm_root::get().find(
            {"uvm_test_top.env.", key, ".completion_worker"}) != null)
            `uvm_fatal("AGENT_WORKER_PATH",
                       "legacy completion worker is still present")
    endfunction

    task run_scenario();
        gq_queue_engine poll_engine;
        gq_queue_engine irq_engine;
        gq_sequencer poll_sequencer;
        gq_sequencer irq_sequencer;
        mailbox_tx_sequence poll_sequence;
        mailbox_tx_sequence irq_sequence;
        mailbox_tx_desc poll_desc;
        mailbox_tx_desc irq_desc;

        cfg.wait_ready();
        if (env.agent_count() != 2)
            `uvm_fatal("AGENT_COUNT", "poll and IRQ agents were not created")
        check_component_tree("tx_12");
        check_component_tree("tx_13");
        poll_engine = find_engine("tx_12");
        irq_engine = find_engine("tx_13");
        poll_sequencer = find_sequencer("tx_12");
        irq_sequencer = find_sequencer("tx_13");

        poll_desc = mailbox_tx_desc::type_id::create("poll_desc");
        poll_desc.srcid = 16'h1201;
        poll_desc.dstid = 16'h1202;
        poll_desc.msg_type = 16'h1203;
        poll_desc.buf_len = 16;
        poll_desc.data_len = 1;
        poll_desc.data[0] = 8'ha5;

        poll_sequence = mailbox_tx_sequence::type_id::create("poll_sequence");
        poll_sequence.add_desc(poll_desc);
        poll_sequence.start(poll_sequencer);
        if (poll_sequence.response == null ||
            poll_sequence.response.status != GQ_OK ||
            poll_sequence.response.committed_count != 1)
            `uvm_fatal("AGENT_DRIVER", "poll driver did not submit TX")

        dut.complete_slot(poll_engine, 0, 32, 64);
        for (int unsigned poll = 0; poll < 2000; poll++) begin
            if (collector.completion_count == 1)
                break;
            #1ns;
        end
        if (collector.completion_count != 1)
            `uvm_fatal("AGENT_MONITOR_TIMEOUT",
                       "poll monitor did not publish completion")

        irq_desc = mailbox_tx_desc::type_id::create("irq_desc");
        irq_desc.srcid = 16'h1301;
        irq_desc.dstid = 16'h1302;
        irq_desc.msg_type = 16'h1303;
        irq_desc.buf_len = 16;
        irq_desc.data_len = 1;
        irq_desc.data[0] = 8'h5a;

        irq_sequence = mailbox_tx_sequence::type_id::create("irq_sequence");
        irq_sequence.add_desc(irq_desc);
        irq_sequence.start(irq_sequencer);
        if (irq_sequence.response == null ||
            irq_sequence.response.status != GQ_OK ||
            irq_sequence.response.committed_count != 1)
            `uvm_fatal("AGENT_DRIVER", "IRQ driver did not submit TX")

        dut.complete_slot(irq_engine, 0, 32, 64);
        dut.trigger_irq(GQ_TX, 13);
        for (int unsigned poll = 0; poll < 2000; poll++) begin
            if (collector.completion_count == 2)
                break;
            #1ns;
        end
        if (collector.completion_count != 2 ||
            adapter.wait_irq_calls == 0 || adapter.ack_irq_calls != 1)
            `uvm_fatal("AGENT_MONITOR_TIMEOUT",
                       "IRQ monitor did not publish and acknowledge completion")
        if (collector.owned_memory_observations != 2)
            `uvm_fatal("AGENT_MONITOR_LIFETIME",
                       "owned TX memory was invalid during analysis write")
        if (poll_engine.head_seq() != 1 || poll_engine.tail_seq() != 1 ||
            irq_engine.head_seq() != 1 || irq_engine.tail_seq() != 1)
            `uvm_fatal("AGENT_MONITOR_STATE",
                       "monitors did not retire both completed descriptors")

        env.cleanup_and_check_leaks();
        if (mem.outstanding_blocks() != 0)
            `uvm_fatal("AGENT_MONITOR_LEAK",
                       "agent cleanup left host memory allocated")
    endtask

    task run_phase(uvm_phase phase);
        bit scenario_done;

        phase.raise_objection(this);
        scenario_done = 0;
        fork : scenario_or_timeout
            begin
                run_scenario();
                scenario_done = 1;
            end
            begin
                #10us;
                if (!scenario_done)
                    `uvm_fatal("AGENT_TEST_TIMEOUT",
                               "agent/monitor scenario did not finish")
            end
        join_any
        disable scenario_or_timeout;
        phase.drop_objection(this);
    endtask
endclass

`endif
```

- [ ] **Step 2: 将新测试加入 package**

在 `tb/gq_test_pkg.sv` 的 `gq_completion_test.sv` 后加入：

```systemverilog
    `include "tests/gq_agent_test.sv"
```

- [ ] **Step 3: 在 53 上运行 RED**

```bash
scripts/run_vcs_remote.sh gq_agent_test
```

Expected：VCS 编译失败，原因是 `gq_monitor` 和/或 `env.get_monitor()` 尚未定义。保存包含该缺失 API 的诊断；不能接受路径错误、语法错误或许可证错误作为 RED。

此时不提交，立即进入 Task 4 GREEN。

---

### Task 4: 实现 monitor-owned completion analysis 路径

**Files:**
- Modify: `src/gq/gq_agent.sv`
- Modify: `src/gq/gq_queue_engine.sv`
- Modify: `src/gq/gq_env.sv`
- Modify: `tb/tests/gq_agent_test.sv`
- Modify: `tb/tests/gq_completion_test.sv`
- Modify: `tb/tests/gq_reset_test.sv`
- Modify: `tb/tests/gq_regression_test.sv`

- [ ] **Step 1: 将 engine analysis port 改为非 owning 绑定**

把公开创建的：

```systemverilog
uvm_analysis_port #(gq_desc_base) completion_ap;
```

改为：

```systemverilog
protected uvm_analysis_port #(gq_desc_base) completion_ap;
```

constructor 中不再 `new("completion_ap", this)`，改为：

```systemverilog
completion_ap = null;
```

新增：

```systemverilog
function void bind_completion_port(
    uvm_analysis_port #(gq_desc_base) port_handle);
    completion_ap = port_handle;
endfunction
```

在完成退休路径中把无条件 write 改为：

```systemverilog
if (completion_ap != null)
    completion_ap.write(desc);
```

保留 write 返回后才调用 `desc.release_owned()` 的顺序。把
`run_completion_worker()` 重命名为 `run_completion_monitor()`，任务体和
persistent cancel/done 行为不变。

- [ ] **Step 2: 用 `gq_monitor` 替代 completion worker**

删除完整的 `gq_completion_worker` class，加入：

```systemverilog
class gq_monitor extends uvm_monitor;
    `uvm_component_utils(gq_monitor)

    gq_queue_engine engine;
    uvm_analysis_port #(gq_desc_base) completion_ap;

    function new(string name = "gq_monitor", uvm_component parent = null);
        super.new(name, parent);
        completion_ap = new("completion_ap", this);
    endfunction

    task run_phase(uvm_phase phase);
        if (engine == null)
            `uvm_fatal("GQ_MONITOR_CFG", "monitor has no queue engine")
        engine.run_completion_monitor();
    endtask
endclass
```

`gq_queue_agent` 的成员必须为：

```systemverilog
gq_queue_engine engine;
gq_sequencer sequencer;
gq_driver driver;
gq_monitor monitor;
```

build 阶段创建：

```systemverilog
monitor = gq_monitor::type_id::create("monitor", this);
```

connect 阶段精确执行：

```systemverilog
driver.engine = engine;
monitor.engine = engine;
engine.bind_completion_port(monitor.completion_ap);
driver.seq_item_port.connect(sequencer.seq_item_export);
```

- [ ] **Step 3: 为 env 增加 monitor 查询 API**

在 `gq_env` 的只读查询函数区域加入：

```systemverilog
function gq_monitor get_monitor(string key);
    if (!agents.exists(key))
        return null;
    return agents[key].monitor;
endfunction
```

- [ ] **Step 4: 更新 focused tests 的 analysis port 绑定**

在 `gq_completion_test` 的成员声明中加入四个由测试拥有的 port：

```systemverilog
uvm_analysis_port #(gq_desc_base) engine_completion_ap;
uvm_analysis_port #(gq_desc_base) poll_completion_ap;
uvm_analysis_port #(gq_desc_base) irq_completion_ap;
uvm_analysis_port #(gq_desc_base) rx_completion_ap;
```

在 `build_phase()` 的 `super.build_phase(phase);` 后创建它们：

```systemverilog
engine_completion_ap = new("engine_completion_ap", this);
poll_completion_ap   = new("poll_completion_ap", this);
irq_completion_ap    = new("irq_completion_ap", this);
rx_completion_ap     = new("rx_completion_ap", this);
```

把 `connect_phase()` 完整替换为：

```systemverilog
function void connect_phase(uvm_phase phase);
    gq_monitor worker_monitor;

    super.connect_phase(phase);
    engine.bind_completion_port(engine_completion_ap);
    engine_completion_ap.connect(collector.analysis_export);
    poll_engine.bind_completion_port(poll_completion_ap);
    poll_completion_ap.connect(poll_collector.analysis_export);
    irq_engine.bind_completion_port(irq_completion_ap);
    irq_completion_ap.connect(irq_collector.analysis_export);
    rx_engine.bind_completion_port(rx_completion_ap);
    rx_completion_ap.connect(rx_collector.analysis_export);

    worker_monitor = worker_env.get_monitor("tx_20");
    if (worker_monitor == null)
        `uvm_fatal("MONITOR_PATH", "could not find tx_20 monitor")
    worker_monitor.completion_ap.connect(worker_collector.analysis_export);
endfunction
```

在 `check_run_phase_worker()` 中把 component 路径和检查改为：

```systemverilog
component_handle = uvm_root::get().find(
    "uvm_test_top.worker_env.tx_20.monitor");
if (component_handle == null)
    `uvm_fatal("MONITOR_PATH", "agent monitor was not built")
```

并把该文件所有 `run_completion_worker()` 调用改为
`run_completion_monitor()`。

在 `gq_reset_test` 的成员声明中加入两个只供直接实例化 engine 使用的测试
port；`tx_7` 属于正常 agent 路径，必须连接 monitor，不得重新绑定 engine：

```systemverilog
uvm_analysis_port #(gq_desc_base) stale_completion_ap;
uvm_analysis_port #(gq_desc_base) irq_completion_ap;
```

在 `build_phase()` 的 `super.build_phase(phase);` 后创建：

```systemverilog
stale_completion_ap = new("stale_completion_ap", this);
irq_completion_ap   = new("irq_completion_ap", this);
```

把 `connect_phase()` 完整替换为：

```systemverilog
function void connect_phase(uvm_phase phase);
    gq_monitor tx_monitor;

    super.connect_phase(phase);
    tx_monitor = env.get_monitor("tx_7");
    if (tx_monitor == null)
        `uvm_fatal("RESET_PATH", "could not find monitor tx_7")
    tx_monitor.completion_ap.connect(collector.analysis_export);

    stale_engine.bind_completion_port(stale_completion_ap);
    stale_completion_ap.connect(stale_collector.analysis_export);
    irq_engine.bind_completion_port(irq_completion_ap);
    irq_completion_ap.connect(irq_collector.analysis_export);
endfunction
```

把该文件所有 `run_completion_worker()` 调用改为
`run_completion_monitor()`。

在 `tb/tests/gq_reset_test.sv` 中，为原先连接 collector 的
`stale_engine`、`irq_engine` 使用上面的测试 analysis port；正常 agent 内的
`tx_engine` 通过 `tx_monitor.completion_ap` 上报。

在 `tb/tests/gq_regression_test.sv` integrated checks 中加入：

```systemverilog
if (env.get_monitor("tx_1") == null ||
    env.get_monitor("tx_4095") == null ||
    env.get_monitor("rx_2") == null ||
    env.get_monitor("rx_3000") == null)
    `uvm_fatal("REG_MONITOR", "sparse queue monitor construction is incorrect")
```

验证旧 API 已清除：

```bash
rg -n 'gq_completion_worker|completion_worker|run_completion_worker|engine\.completion_ap' src tb
```

Expected：无输出。

- [ ] **Step 5: 运行 focused GREEN**

Run on `10.11.10.53`：

```bash
scripts/run_vcs_remote.sh gq_agent_test
scripts/run_vcs_remote.sh gq_completion_test
scripts/run_vcs_remote.sh gq_reset_test
scripts/run_vcs_remote.sh gq_regression_test
```

Expected：四项均 exit 0、最终 W/E/F=`0/0/0`、每条 HOST_MEM leak 为 0；
`gq_agent_test` 必须分别通过 poll/IRQ monitor 收到两个 analysis transaction，
检查 IRQ ACK，并在两次同步回调中验证 owned memory lifetime。

- [ ] **Step 6: 静态检查并提交组件化改造**

```bash
make check-layout
git diff --check
git add src/gq tb/gq_test_pkg.sv tb/tests
git commit -m "refactor: expose completions through queue monitor"
```

---

### Task 5: 将主 README 全文改为中文

**Files:**
- Modify: `README.md`
- Modify: `scripts/check_sv_layout.sh`

- [ ] **Step 1: 用以下完整中文内容替换 `README.md`**

使用 `apply_patch` 将 `README.md` 整体替换为以下内容。代码、标识符、命令和
路径保持英文，所有说明文字使用中文：

````markdown
# 通用队列 UVM 验证环境

本仓库提供一个支持稀疏队列和复位的 UVM 通用队列环境，以及基于它实现的
mailbox 特化环境。队列 ring 使用 64-bit host 地址，硬件 tail pointer 使用
32-bit 编码值，软件 head/tail 位置使用 64-bit logical sequence。availability
phase 每经过一整圈 queue depth 翻转一次，因此长时间运行的测试无需截断
logical sequence。

仓库自有 class 文件使用 `.sv` 扩展名，但仍分别由 `src/gq/gq_pkg.sv`、
`src/mailbox/mailbox_pkg.sv` 和 `tb/gq_test_pkg.sv` 通过 `` `include`` 引入；
它们不是需要单独加入编译列表的独立 source。第三方 `uvm_macros.svh` 保持
原扩展名。

## 配置内存与稀疏队列

向环境配置注入一个共享的 `host_mem_api` 实现和一个 DUT 专用的
`gq_hw_adapter`。只有显式加入 `queues` 的队列才会创建 agent 并预分配 ring；
未使用的 queue 不分配实际内存。

下面示例中的 `my_mailbox_adapter` 是用户工程提供的具体类，它扩展
`gq_hw_adapter` 并实现队列寄存器和 IRQ 访问。`my_mailbox_ptr_codec` 同样是
用户工程针对 DUT raw pointer layout 实现的 `gq_ptr_codec`。这两个名字都不
是本仓库 testbench 中的 mock。

```systemverilog
function gq_queue_cfg make_mailbox_queue_cfg(
    string name,
    gq_role_e role,
    int unsigned queue_id,
    int unsigned depth,
    gq_wait_mode_e wait_mode,
    time poll_interval,
    time completion_timeout,
    gq_ptr_codec ptr_codec);
    gq_queue_cfg queue_cfg;

    queue_cfg = gq_queue_cfg::type_id::create(name);
    queue_cfg.queue_id           = queue_id;
    queue_cfg.role               = role;
    queue_cfg.depth              = depth;
    queue_cfg.desc_size          = role == GQ_TX ? 64 : 16;
    queue_cfg.alignment          = 64;
    queue_cfg.status_area_size   = 0;
    queue_cfg.wait_mode          = wait_mode;
    queue_cfg.poll_interval      = poll_interval;
    queue_cfg.completion_timeout = completion_timeout;
    queue_cfg.ptr_codec          = ptr_codec;
    queue_cfg.completion_source  = mailbox_completion::type_id::create(
        {name, "_completion"});
    return queue_cfg;
endfunction

host_mem_manager mem;
my_mailbox_adapter adapter;
my_mailbox_ptr_codec codec;
mailbox_env_cfg cfg;
mailbox_env env;
gq_queue_cfg tx_1_cfg;
gq_queue_cfg tx_4095_cfg;
gq_queue_cfg rx_2_cfg;
gq_queue_cfg rx_3000_cfg;
string reason;

mem = new("mem");
mem.init_region(64'h0000_0001_0000_0000,
                64'h0000_0001_00ff_ffff, MODE_LINEAR, 16);
adapter = my_mailbox_adapter::type_id::create("adapter");
codec = my_mailbox_ptr_codec::type_id::create("codec");

cfg = mailbox_env_cfg::type_id::create("cfg");
cfg.mem       = mem;
cfg.adapter   = adapter;
cfg.ptr_codec = codec;

tx_1_cfg = make_mailbox_queue_cfg(
    "tx_1_cfg", GQ_TX, 1, 32, GQ_POLL, 100ns, 10us, codec);
tx_4095_cfg = make_mailbox_queue_cfg(
    "tx_4095_cfg", GQ_TX, 4095, 32, GQ_IRQ, 100ns, 10us, codec);
rx_2_cfg = make_mailbox_queue_cfg(
    "rx_2_cfg", GQ_RX, 2, 32, GQ_POLL, 100ns, 10us, codec);
rx_3000_cfg = make_mailbox_queue_cfg(
    "rx_3000_cfg", GQ_RX, 3000, 32, GQ_IRQ, 100ns, 10us, codec);

if (!cfg.add_queue(tx_1_cfg, reason) ||
    !cfg.add_queue(tx_4095_cfg, reason) ||
    !cfg.add_queue(rx_2_cfg, reason) ||
    !cfg.add_queue(rx_3000_cfg, reason))
    `uvm_fatal("QUEUE_CFG", reason)

uvm_config_db#(gq_env_cfg)::set(this, "env", "cfg", cfg);
env = mailbox_env::type_id::create("env", this);
```

mailbox 配置会验证 queue ID 位于 `0..4095`，depth 位于 `32..65536` 且为
2 的幂，TX descriptor 为 64-byte，RX descriptor 为 16-byte。成功执行
`add_queue` 后，该 queue configuration 的所有权转移给环境。调用前必须设置
完所有 field 和 strategy；调用后不得通过原 handle 或 `cfg.queues` 修改它。
`add_tx`/`add_rx` helper 会安装 mailbox 默认值；如果某个 queue 需要自定义
wait 或 timeout policy，应像上面示例一样显式构造 `gq_queue_cfg`。

## 扩展描述符与指针编解码器

协议 descriptor 从 `gq_desc_base` 派生。实现 `prepare()` 以管理
transaction buffer 所有权，并实现 `mark_available(phase)`、固定大小的
`pack()`/`unpack()`、`is_complete(phase)`，以及协议存在 writeback data 时的
completion parsing。transaction buffer 必须通过 `alloc_owned()` 分配，使
completion、reset 和 final cleanup 都能且只能释放一次。可参考
`mailbox_tx_desc` 和 `mailbox_rx_desc` 的 64-byte 与 16-byte 具体实现。
mailbox descriptor 按 little-endian 编解码。

completion storage/writeback 是同一设计内跨 role、跨 queue 固定的
design-level mechanism 和 strategy type，不是每个 queue 可切换的硬件模式。
每个 `gq_queue_cfg` 仍保存独立的 `completion_source` object，使实例能够携带
queue-specific parameter 或 state。派生环境必须为所有 queue 验证或安装设计
要求的 strategy type，并在需要时创建相互独立的实例。例如，
`mailbox_env_cfg` 强制 TX/RX queue 使用 `mailbox_completion`；使用
`gq_tail_mem_completion` 的设计则可以为每个 queue 的实例设置相应 pointer
codec、byte offset 和 byte order，而不改变该设计固定的 completion mechanism。

硬件 pointer format 从 `gq_ptr_codec` 派生并实现：

```systemverilog
virtual function gq_raw_ptr_t encode_publish(
    gq_logical_seq_t old_tail,
    gq_logical_seq_t new_tail,
    int unsigned depth);

virtual function bit decode_completion(
    gq_raw_ptr_t raw,
    gq_logical_seq_t logical_head,
    int unsigned depth,
    output gq_logical_seq_t completed_tail);
```

所有 wrap 决策都应放在 codec 中，descriptor phase 使用
`gq_phase(sequence, depth)`。具体 codec 属于用户工程，因为 raw head/tail
表示由 DUT 决定。

## 使用标准 UVM Agent

每个已配置 queue 都创建一个主动 `gq_queue_agent`：

```text
gq_queue_agent
├── gq_sequencer
├── gq_driver
├── gq_monitor
│   └── completion_ap
└── gq_queue_engine
```

`gq_driver` 从 sequence 接收 request，负责 TX submit 和 RX first start；
`gq_monitor` 负责 poll/IRQ completion，并只通过 `completion_ap` 上报 DUT 已
完成且已经解析的 descriptor；共享的 `gq_queue_engine` 保存 ring、descriptor、
refill、reset 和并发状态。当前 agent 只支持主动模式，不实现 `UVM_PASSIVE`。

上层 scoreboard 可在 `connect_phase()` 中通过环境的只读查询接口连接 monitor：

```systemverilog
function void connect_phase(uvm_phase phase);
    gq_monitor monitor;

    super.connect_phase(phase);
    monitor = env.get_monitor("tx_1");
    if (monitor == null)
        `uvm_fatal("MONITOR", "tx_1 monitor was not created")
    monitor.completion_ap.connect(scoreboard.analysis_export);
endfunction
```

analysis `write()` 是同步生命周期边界。回调返回前，descriptor-owned memory
保持有效；回调返回后 engine 才会释放 owned memory 并退休 descriptor。
subscriber 如果需要在 `write()` 返回后长期保存结果，必须在回调中复制所需的
非 owning 解析数据。

## 在硬件适配器中实现发布取消

具体的 `gq_hw_adapter` 可以阻塞在
`publish(role, queue_id, raw_tail)` 内。对于相同 role 和 queue ID，
`disable_queue(role, queue_id)` 是正在阻塞的 `publish()` 的取消操作；adapter
必须允许两个 task 并发运行。每次重叠必须严格线性化为以下两种顺序之一：

- 如果 `publish()` 先线性化，它的 tail update 可能已经可见，此调用必须作为
  不可取消的 publish 继续完成；之后的 `disable_queue()` 不能追溯撤销已经
  可见的更新。
- 如果 `disable_queue()` 先生效，尚未线性化的 publish 被取消，并且必须返回，
  不能等待 engine teardown 或 queue-memory release。从该 disable boundary
  开始，被取消的调用不能再产生新的 tail-visible side effect；特别是
  `disable_queue()` 返回后，它的 tail 不得变为可见。

adapter 必须让 publish linearization、task completion 和可见 tail side effect
保持一致。不能在硬件 tail 已经可见时，仍把同一次调用视为可取消的 pending
work。public interface 有意不提供独立的 `cancel_publish()` task；实现可以在
`publish()` 和 `disable_queue()` 后使用 private cancellation helper 或 state。

disable-first 情况可以直接测试：让 publish 在 linearization point 之前阻塞，
并发调用 disable，再验证 publish 返回且被取消的 tail 始终不可见。这是
cancellation 和 quiescence contract，不是 cancellation-timeout contract。

`disable_queue()` 返回本身不能证明对应的 SystemVerilog `publish()` task 已经
unwind。engine 会跟踪这个确切的 in-flight task，并等待它的 done event，之后
才释放或复用 descriptor-owned buffer、queue ring 或任何 backing memory。
adapter 不检查 engine done event，也不释放 host storage。反过来，`publish()`
返回是该次调用的 adapter quiescence boundary：返回后不得留下仍会访问 queue
或 backing storage、或延迟暴露 tail update 的工作。这两项职责允许 disable
先于 task unwind 返回，同时避免 engine 过早释放 storage。

`publish()` 正常返回只代表 adapter call 到达 quiescence boundary，不会自动
使 sequence response 成功，也不会设置 `committed_count`。engine 会先根据当前
epoch 和 queue lifecycle 重新验证；只有仍然有效的操作才向 caller 报告为已
发布。如果 runtime reset 使 in-flight user TX publish 失效，即使 adapter task
正常返回，response 仍为 `GQ_ABORTED_BY_RESET`。

## 提交 TX 任务

同一种 sequence 可表示单个 request 或一个 atomic batch。只有实际提交的 TX
transaction 才分配 descriptor-owned transaction buffer，不会按 ring depth
预分配所有 payload。engine 为内部 submit transaction 取得 descriptor 所有权
后，会在 publish 和 reset 过程中持续承担 cleanup 责任；只有 publish 返回并
完成 epoch/lifecycle 复核后，才决定 caller-visible success。

```systemverilog
mailbox_tx_sequence tx;
mailbox_tx_desc desc;

tx = mailbox_tx_sequence::type_id::create("single_tx");
desc = mailbox_tx_desc::type_id::create("desc");
desc.srcid = 1;
desc.dstid = 2;
desc.data_len = 1;
desc.data[0] = 8'ha5;
tx.add_desc(desc);
tx.start(tx_sequencer);
if (tx.response.status != GQ_OK || tx.response.committed_count != 1)
    `uvm_fatal("TX", "single submit failed")

tx = mailbox_tx_sequence::type_id::create("batch_tx");
tx.add_desc(first_desc);
tx.add_desc(second_desc);
tx.add_desc(third_desc);
tx.start(tx_sequencer);
if (tx.response.status != GQ_OK || tx.response.committed_count != 3)
    `uvm_fatal("TX", "batch submit failed")
```

## 一次性启动 RX

RX startup 是一次性操作。engine 克隆传入的 profile，先发布
`initial_post_count` 个 descriptor；之后只有 DUT 实际退休 descriptor，使
posted count 降到 `low_watermark` 或以下时，才自动 refill 到
`high_watermark`。RX buffer 随 descriptor 预填和后续 refill 分配，用于接收
DUT 写入的数据。

```systemverilog
mailbox_refill_profile profile;
mailbox_rx_start_sequence start_rx;

profile = mailbox_refill_profile::type_id::create("profile");
profile.initial_post_count  = 4;
profile.low_watermark       = 2;
profile.high_watermark      = 6;
profile.restart_after_reset = 1;
profile.min_buf_len         = 256;
profile.max_buf_len         = 2048;

start_rx = mailbox_rx_start_sequence::type_id::create("start_rx");
start_rx.set_refill_profile(profile);
start_rx.start(rx_sequencer);
if (start_rx.response.status != GQ_OK)
    `uvm_fatal("RX", "RX startup failed")
```

第二次 startup request 返回 `GQ_RESOURCE_ERROR`。当
`restart_after_reset=1` 时，reset recovery 使用保存的初始 profile 重新发布，
不会接受新的用户 startup。

## 选择轮询或中断完成模式

poll 和 IRQ 模式共用同一条有序 drain 路径。像前面的配置示例一样，在
`gq_queue_cfg` 成功执行 `add_queue` 前设置 `wait_mode`、`poll_interval` 和
`completion_timeout`；所有权转移后不得再通过 `cfg.queues` 修改这些值。

IRQ 模式下 adapter 实现 `wait_irq()` 和 `ack_irq()`，timeout 同时限制 IRQ
wait。completion diagnostic 从 tail publish 返回后开始计算 age，对每次最老
outstanding episode 只报告一次，并包含 role、queue ID、head、tail、slot、
phase、ring/slot address 和 descriptor bytes。

## 驱动复位与最终清理

reset assertion/deassertion 是由环境 reset controller 消费的 persistent
event。必须检查 boolean result，避免 duplicate 或 out-of-order edge 被静默
忽略。

```systemverilog
if (!cfg.trigger_reset_asserted())
    `uvm_fatal("RESET", "reset assertion rejected")
// Wait for DUT reset/queue-disable synchronization here.
if (!cfg.trigger_reset_deasserted())
    `uvm_fatal("RESET", "reset release rejected")
```

测试应正常放下最后一个 run-phase objection。当 run phase 即将结束时，环境会
提出自己的 objection，停止新 submission 并 quiesce completion activity。
随后对每个 queue disable hardware（或加入已经开始的 disable），等待确切的
in-flight `publish()` task unwind，释放 outstanding descriptor-owned buffer，
最后释放 ring backing allocation。所有 queue 到达这一边界后，环境执行一次
共享 memory leak check，再放下 objection。runtime reset 后也可以安全执行
automatic finalization。仍支持显式提前调用 `cleanup_and_check_leaks()`；并发或
重复调用会加入同一个 idempotent finalization。

```systemverilog
phase.drop_objection(this);
```

## 使用 VCS 运行

在已经加载 VCS 和 UVM license 环境的机器上运行：

```bash
make run TEST=gq_regression_test
```

仓库 helper 会把当前 working-tree 内容复制到 `10.11.10.53`，进入该主机的
interactive login 环境，使用 VCS build 并运行一个测试，最后删除远端临时
目录。`rsync` 会包含 tracked working-tree modification 和 untracked file，
但明确排除 `.git`、`.superpowers` 和 `build`；它不要求也不表示本地 tree 已
commit 或 clean。

```bash
./scripts/run_vcs_remote.sh gq_regression_test
```

使用以下精确命令运行完整回归：

```bash
./scripts/run_vcs_remote.sh gq_agent_test
./scripts/run_vcs_remote.sh gq_config_test
./scripts/run_vcs_remote.sh mailbox_desc_test
./scripts/run_vcs_remote.sh gq_submit_test
./scripts/run_vcs_remote.sh gq_completion_test
./scripts/run_vcs_remote.sh gq_refill_test
./scripts/run_vcs_remote.sh gq_reset_test
./scripts/run_vcs_remote.sh gq_regression_test
```

helper 使用的底层远端命令为：

```bash
remote_copy=/tmp/queue_work-vcs-run
ssh ubuntu@10.11.10.53 \
  "cd '$remote_copy' && bash -lc 'bash -ic \"make run TEST=gq_regression_test\"'"
```

实际 helper 会为每次运行动态生成并清理 `remote_copy`，这里的固定路径仅展示
login-shell 调用结构。
````

- [ ] **Step 2: 让布局检查覆盖 README 的失效路径和 monitor API**

在 `scripts/check_sv_layout.sh` 的 `exit "$status"` 前加入：

```bash
mapfile -t stale_readme_refs < <(
    rg -n 'gq_completion_worker|run_completion_worker|(?:src|tb)/[^`[:space:]]+\.svh' \
        README.md || true
)
if ((${#stale_readme_refs[@]} != 0)); then
    printf 'stale README source or worker references remain:\n' >&2
    printf '  %s\n' "${stale_readme_refs[@]}" >&2
    status=1
fi

required_readme_refs=(
    'src/gq/gq_pkg.sv'
    'src/mailbox/mailbox_pkg.sv'
    'tb/gq_test_pkg.sv'
    'gq_monitor'
    'get_monitor("tx_1")'
)
for required_ref in "${required_readme_refs[@]}"; do
    if ! rg -Fq "$required_ref" README.md; then
        printf 'README is missing required reference: %s\n' \
            "$required_ref" >&2
        status=1
    fi
done
```

- [ ] **Step 3: 运行文档和布局检查**

```bash
make check-layout
rg -n '^#{1,4} ' README.md
rg -n 'gq_completion_worker|run_completion_worker|\.svh' README.md
git diff --check
```

Expected：README 标题全部为中文；旧 worker API 无匹配；`.svh` 只允许在
解释第三方 `uvm_macros.svh` 时出现，否则无匹配。

- [ ] **Step 4: 提交中文 README**

```bash
git add README.md scripts/check_sv_layout.sh
git diff --cached --check
git commit -m "docs: translate queue environment guide to Chinese"
```

---

### Task 6: 全范围验证与最终清理

**Files:**
- Verify only; production changes are not expected.

- [ ] **Step 1: 运行静态检查**

```bash
make check-layout
bash -n scripts/check_sv_layout.sh
make -n run TEST=gq_agent_test
rg --files src tb | rg '\.svh$'
rg -n 'gq_completion_worker|completion_worker|run_completion_worker|engine\.completion_ap' src tb README.md
git diff --check master..HEAD
git status --short
git submodule status
```

Expected：两个 `rg` 旧布局/API 检查无输出；其他命令 exit 0；submodule 为
前导空格的
`3b9e000d5df4d10efbb3029f43605e0362e0caca host_mem`。

- [ ] **Step 2: 在 53 上运行八项完整 VCS 回归**

依次运行：

```bash
scripts/run_vcs_remote.sh gq_agent_test
scripts/run_vcs_remote.sh gq_config_test
scripts/run_vcs_remote.sh mailbox_desc_test
scripts/run_vcs_remote.sh gq_submit_test
scripts/run_vcs_remote.sh gq_completion_test
scripts/run_vcs_remote.sh gq_refill_test
scripts/run_vcs_remote.sh gq_reset_test
scripts/run_vcs_remote.sh gq_regression_test
```

每项必须同时满足：process exit 0、final UVM W/E/F=`0/0/0`、每条
HOST_MEM 都是 `Leak check passed: 0 blocks outstanding`。

- [ ] **Step 3: 核对提交范围和敏感信息**

```bash
git log --oneline master..HEAD
git diff --stat master..HEAD
git diff --check master..HEAD
git grep -nE 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}' -- .
```

Expected：前三项只包含设计、`.sv` 迁移、monitor 组件和中文 README；secret
scan 无匹配。不要把认证信息写入 remote、credential helper、脚本或文档。

- [ ] **Step 4: 请求规格审查和代码质量审查**

规格审查必须逐项核对设计文档第 9 节完成标准。规格通过后再进行质量审查，
重点检查：

- monitor/engine port ownership 与 descriptor lifetime；
- reset/cleanup 时 monitor loop 是否可退出；
- direct-engine tests 是否显式绑定所需 analysis port；
- package include 顺序和重复编译风险；
- 中文 README 是否与 API/实现一致。

修复所有 Critical/Important，并分别重新审查直到通过。

- [ ] **Step 5: 最终确认工作区干净**

```bash
git status --short --branch
git submodule status
git show --check --oneline HEAD
```

Expected：worktree 无未提交修改，submodule clean，最后提交无 whitespace 错误。
