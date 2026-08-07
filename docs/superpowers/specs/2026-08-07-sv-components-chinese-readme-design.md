# SystemVerilog `.sv`、标准 UVM 组件与中文 README 迁移设计

## 1. 背景

当前通用队列与 mailbox 验证环境已经具备 sequencer、driver、队列引擎、
完成处理线程、复位控制和自动清理能力，但存在三项可维护性问题：

1. `src/`、`tb/mocks/` 和 `tb/tests/` 中的 31 个仓库自有文件使用
   `.svh` 扩展名，用户期望统一使用 `.sv`。
2. 完成处理由 `gq_completion_worker` 执行，完成 analysis port 属于
   `gq_queue_engine`，组件层次不是标准的 sequencer/driver/monitor agent。
3. 主 `README.md` 使用英文，不符合项目使用者的中文文档要求。

本次迁移只调整源文件组织、UVM 组件职责和主使用文档，不改变描述符格式、
队列协议、内存所有权、tail 发布、完成判定、RX refill 或复位语义。

## 2. 已确认决策

- 仓库自有 `.svh` 文件全部重命名为 `.sv`。
- 重命名后的 class 文件继续由现有 package `.sv` 文件通过 `` `include``
  引入，不改为独立编译单元。
- `uvm_macros.svh` 等第三方文件保持原名。
- agent 仅支持当前主动模式，每个启用队列都创建 sequencer、driver 和
  monitor；本次不设计 `UVM_PASSIVE`。
- driver 负责 sequence request、TX submit 和 RX 首次启动。
- monitor 负责 poll/IRQ 完成处理，只上报 DUT 已完成的描述符。
- `gq_queue_engine` 保留为 driver 与 monitor 共享的队列状态、内存、refill、
  reset 和并发控制核心。
- 主 `README.md` 全文改为中文；SystemVerilog 标识符、命令和代码示例保持
  原始英文形式。
- 历史规格和计划中的仓库自有文件路径同步更新为 `.sv`，但历史文档正文
  不做无关翻译。

## 3. 文件组织迁移

### 3.1 重命名范围

以下目录中的所有仓库自有 `.svh` 文件使用 `git mv` 改为 `.sv`：

- `src/gq/`
- `src/mailbox/`
- `tb/mocks/`
- `tb/tests/`

`src/gq/gq_pkg.sv`、`src/mailbox/mailbox_pkg.sv` 和
`tb/gq_test_pkg.sv` 保持为 package 编译入口。三个文件仍按当前依赖顺序
include class 文件，只把自有 include 路径从 `.svh` 更新为 `.sv`。

Makefile 仍只把以下文件作为项目编译入口：

- `host_mem/src/host_mem_pkg.sv`
- `src/gq/gq_pkg.sv`
- `src/mailbox/mailbox_pkg.sv`
- `tb/gq_test_pkg.sv`
- `tb/tb_top.sv`

重命名后的 class `.sv` 文件不得再次加入 `SOURCES`，否则同一 class 会被
重复编译。

### 3.2 Include guard

每个重命名文件的 guard 同步从 `*_SVH` 改为 `*_SV`。例如：

```systemverilog
`ifndef GQ_AGENT_SV
`define GQ_AGENT_SV
...
`endif
```

迁移后 `src/` 和 `tb/` 中不得残留仓库自有 `.svh` 文件或指向它们的
include；`uvm_macros.svh` 是允许保留的第三方例外。

## 4. 标准 UVM Agent 架构

每个已配置队列对应一个主动 `gq_queue_agent`：

```text
gq_queue_agent
├── gq_sequencer
├── gq_driver
│   └── TX submit / RX first start
├── gq_monitor
│   ├── poll / IRQ completion loop
│   └── completion_ap
└── gq_queue_engine
    └── ring / descriptor / refill / reset / concurrency state
```

### 4.1 `gq_driver`

`gq_driver` 继续扩展
`uvm_driver #(gq_request, gq_response)`，并保持现有 request/response 行为：

- `GQ_SUBMIT` 调用 engine 的批量提交接口。
- `GQ_START_RX` 调用 engine 的一次性 RX 启动接口。
- response 保留 request ID，继续报告 `status`、`committed_count` 和
  `reset_epoch`。
- driver 在 engine ready 后才从 sequencer 取 item。

本次不把 completion 或 RX 自动 refill 移入 driver。

### 4.2 `gq_monitor`

新增 `gq_monitor extends uvm_monitor`，替代并删除
`gq_completion_worker`。monitor 包含：

- 一个指向同队列 `gq_queue_engine` 的 handle；
- 一个由 monitor 创建并拥有的
  `uvm_analysis_port #(gq_desc_base) completion_ap`；
- 一个 `run_phase`，调用 engine 的完成监控循环。

如果 `run_phase` 开始时 engine 为空，monitor 必须使用定点 ID
`GQ_MONITOR_CFG` 报告 `uvm_fatal`。完成循环同时支持已有 poll 和 IRQ
策略，并在 engine shutdown 后正常返回。

monitor 只发送已由 completion source 判定完成、且已完成
`parse_completion()` 的 descriptor。analysis 写入是同步的：subscriber 的
`write()` 返回前 descriptor-owned memory 仍有效，返回后 engine 才能释放
owned memory 并退休该 descriptor。

### 4.3 `gq_queue_engine` 与 analysis port

`gq_queue_engine` 不再创建或公开拥有自己的 `completion_ap`。它只保存
monitor analysis port 的非 owning handle，并提供只用于组件连接的绑定
函数。绑定规则如下：

- `gq_queue_agent::connect_phase` 把 `monitor.completion_ap` 绑定给 engine。
- engine 不创建、销毁或重新绑定 monitor 的 port。
- agent 正常路径必须完成绑定。
- 直接实例化 engine 的 focused test 可以不绑定 port；此时完成仍可退休，
  但不会产生 analysis transaction。
- 需要验证完成数据的 focused test 必须创建测试 analysis port、绑定给
  engine，再连接 collector。

engine 的完成循环名称改为 monitor 语义，例如
`run_completion_monitor()`；原 `run_completion_worker()` API 和
`gq_completion_worker` class 不再保留。

### 4.4 `gq_queue_agent` 与 `gq_env`

`gq_queue_agent` 始终创建：

- `engine`
- `sequencer`
- `driver`
- `monitor`

connect 阶段完成以下连接：

1. driver 绑定 engine；
2. monitor 绑定 engine；
3. engine 绑定 monitor 的 `completion_ap`；
4. driver 的 `seq_item_port` 连接 sequencer 的 `seq_item_export`。

`gq_env` 保持 sparse queue agent 创建方式，并新增只读
`get_monitor(string key)` 查询函数。不存在对应队列时返回 `null`。用户可在
上层 component 的 `connect_phase` 中通过该函数取得 monitor 并连接
scoreboard，不需要访问 protected agent 数组或使用层次路径查找。

## 5. 数据流与生命周期

### 5.1 发送和 RX 启动

```text
sequence
  -> sequencer
  -> driver
  -> queue engine prepare/install/publish
  -> response
```

descriptor、payload buffer、tail publish 和 reset epoch 复核语义保持不变。

### 5.2 完成监控

```text
completion source (poll or IRQ)
  -> monitor run loop
  -> queue engine ordered drain
  -> descriptor parse_completion()
  -> monitor.completion_ap.write(desc)
  -> subscriber returns
  -> release_owned() and retire
  -> RX refill when required
```

monitor 不复制 owning descriptor。subscriber 如果需要跨 `write()` 保存
数据，必须在同步回调内复制非 owning 的解析结果。

### 5.3 Reset 和 cleanup

reset、cleanup 和 blocked publish cancellation 的所有权继续属于 engine。
monitor 不直接 disable queue，也不释放 ring 或 descriptor。engine 继续保证：

1. 停止新流量并取消完成等待；
2. disable queue；
3. 等待 exact in-flight publish 返回；
4. 释放 descriptor-owned memory；
5. 释放 ring backing memory。

monitor completion loop 必须使用现有 persistent cancel/done 事件退出，不能
新增基于固定延时的终止逻辑。

## 6. 中文 README

主 `README.md` 的标题、说明文字、列表、表格标题和注意事项全部改为中文。
以下内容保留英文原文形式，避免破坏可复制性和 API 精度：

- class、method、field、enum 和 report ID；
- SystemVerilog 代码块；
- shell/Make 命令；
- 文件路径和 Git 分支名。

README 需要明确说明：

- `.sv` class 文件仍由 package include，不是独立编译单元；
- agent 是主动 agent，包含 sequencer、driver、monitor 和 engine；
- driver 与 monitor 的职责边界；
- 使用 `env.get_monitor(key).completion_ap` 连接 scoreboard 的示例；
- descriptor、TX batch、RX startup/refill、poll/IRQ、reset、publish cancel、
  自动 cleanup 和 VCS 运行方式。

现有技术契约不得因翻译而弱化，特别是 publish/disable 线性化、exact publish
done 后释放内存、design-level completion mechanism 和 descriptor ownership。

## 7. 验证策略

### 7.1 结构 RED/GREEN

新增结构检查脚本和 Make target。脚本在迁移前必须因为 31 个仓库自有
`.svh` 文件而失败；迁移后必须通过。检查内容包括：

- `src/`、`tb/mocks/`、`tb/tests/` 不存在 `.svh` 文件；
- package 不 include 自有 `.svh`；
- `uvm_macros.svh` 仍允许存在；
- 重命名文件不存在 `_SVH` include guard；
- README 与当前 package/monitor 路径一致。

### 7.2 Agent/monitor RED/GREEN

新增 focused UVM test，在 monitor 实现前必须因缺少 `gq_monitor` 或目标组件
结构而失败。GREEN 必须验证：

- agent 同时创建 sequencer、driver、monitor 和 engine；
- `gq_completion_worker` 不存在于组件层次；
- driver request 仍能完成 TX submit；
- poll/IRQ 完成通过 monitor `completion_ap` 同步送达 collector；
- collector 观察期间 owned memory 有效，回调返回后最终无泄漏；
- reset/cleanup 后 monitor loop 能退出。

### 7.3 回归

所有仿真必须在 `10.11.10.53` 的 login shell 环境运行。至少执行：

- 新增 agent/monitor focused test；
- `gq_config_test`；
- `mailbox_desc_test`；
- `gq_submit_test`；
- `gq_completion_test`；
- `gq_refill_test`；
- `gq_reset_test`；
- `gq_regression_test`。

每项验收条件：

- 进程 exit code 为 0；
- 最终 UVM warning/error/fatal 为 `0/0/0`；
- 每条 HOST_MEM leak check 都是 `0 blocks outstanding`。

## 8. 非目标

- 不实现 `UVM_PASSIVE` agent。
- 不把每个 class `.sv` 改为独立 package 或独立编译单元。
- 不改变 mailbox TX 64-byte、RX 16-byte descriptor layout。
- 不改变 little-endian 编码、queue ID/depth 约束或 wrap phase。
- 不改变 host_mem submodule。
- 不改变 DUT adapter、completion source、RX refill 或 reset 的协议语义。
- 不翻译历史规格/计划全文，只同步其中失效的自有文件路径。

## 9. 完成标准

迁移完成时必须同时满足：

1. 31 个仓库自有 `.svh` 已全部迁移为 `.sv`；
2. package 编译入口和 include 顺序保持正确；
3. agent 具有 sequencer、driver、monitor 和共享 engine；
4. 完成 analysis port 由 monitor 拥有并可由 scoreboard 连接；
5. 主 README 为中文且契约与实现一致；
6. 结构检查、新 focused test 和现有七项 VCS 回归全部通过；
7. worktree、submodule、diff check 和敏感信息扫描干净。
