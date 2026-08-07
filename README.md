# 通用队列 UVM 验证环境

本仓库提供一个稀疏、感知复位的 UVM 队列环境及其 mailbox 特化实现。队列环使用
64-bit host address，硬件 tail pointer 是 32-bit 编码后的 raw value，而软件 head/tail
位置采用 64-bit logical sequence。每经过一整圈 queue depth，availability phase 翻转
一次，因此长时间运行的测试无需截断 logical sequence number。

## 配置内存与稀疏队列

仓库自有的 class 源文件使用 `.sv` 后缀，并分别由 `src/gq/gq_pkg.sv`、
`src/mailbox/mailbox_pkg.sv` 与 `tb/gq_test_pkg.sv` 通过 package include 汇总编译；
它们不是构建系统中彼此独立的 `SOURCES`。`uvm_macros.svh` 是唯一保留的第三方
`.svh` include。

请向环境配置注入一个共享的 `host_mem_api` 实现、一个 DUT 专用的
`gq_hw_adapter`，以及对应的 `gq_ptr_codec`。只有显式加入 `queues` 的队列才会分配
agent 或预分配 ring；未使用的 queue 不占用实际内存。

下面的例子中，`my_mailbox_adapter` 是用户项目提供的具体 class；它扩展
`gq_hw_adapter` 并实现 queue register/IRQ 访问。`my_mailbox_ptr_codec` 同样是用户项目
为 DUT raw pointer 布局提供的具体 `gq_ptr_codec`。这两个名称都不是本仓库中的
testbench mock。

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

mailbox 配置接受 `0..4095` 的 queue ID、`32..65536` 范围内且为 2 次幂的 depth、
64-byte TX descriptor 和 16-byte RX descriptor。descriptor 采用 little-endian 布局，
地址为 64-bit。`add_queue` 成功后，queue configuration 的 ownership 转移给环境；
调用前必须设置全部 field 与 strategy，之后不得再通过原 handle 或 `cfg.queues` 修改
该 queue configuration。`add_tx`/`add_rx` helper 会安装 mailbox 默认值；若某个 queue
需要定制 wait 或 timeout policy，应像上例一样显式构造 `gq_queue_cfg`。

## 扩展描述符与指针编解码器

protocol descriptor 应派生自 `gq_desc_base`。实现 `prepare()` 以管理 transaction
buffer ownership，并实现 `mark_available(phase)`、固定大小的 `pack()`/`unpack()`、
`is_complete(phase)`，以及协议存在 writeback data 时的 completion parsing。使用
`alloc_owned()` 分配 transaction buffer，使 completion、reset 与最终 cleanup 都能且
只能释放一次。具体的 64-byte 与 16-byte 实现可参考 `mailbox_tx_desc` 和
`mailbox_rx_desc`。TX transaction buffer 按实际 request 分配；RX buffer 则随着初始
prefill 和后续 refill 分配，不会按未使用 queue 或理论容量预先占用内存。

completion storage/writeback 是同一 design 内跨 role、跨 queue 固定的 design-level
mechanism 和 strategy type，并不是逐 queue 选择的 hardware-mode switch。源码仍在每个
`gq_queue_cfg` 中保存一个 `completion_source` object，使不同 instance 能携带逐 queue
的 parameter 或 state。派生环境必须为每个 queue 校验或安装该 design 要求的 strategy
type，并在需要时创建彼此独立的 instance。例如，`mailbox_env_cfg` 要求每个 TX 和 RX
queue 都使用 `mailbox_completion` instance；采用 `gq_tail_mem_completion` 的 design
则可以让每个 queue instance 携带适用的 pointer codec、byte offset 与 byte order，
而不改变 design-level completion mechanism。

hardware pointer format 应派生自 `gq_ptr_codec`，并实现以下两个 virtual function：

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

所有 wrap 判断都必须留在 codec 中，descriptor phase 使用
`gq_phase(sequence, depth)` 计算。raw head/tail 表示由 DUT 决定，因此具体 codec
属于用户项目。

## 使用标准 UVM Agent

每个显式配置的 queue 都会创建一个标准 active UVM agent，结构如下：

```text
gq_queue_agent
├── gq_sequencer
├── gq_driver
├── gq_monitor
│   └── completion_ap
└── gq_queue_engine
```

`gq_driver` 负责 TX submit 和 RX 首次 start；`gq_monitor` 负责 poll/IRQ completion，
且只通过 `completion_ap` 上报 DUT 已完成的 descriptor；`gq_queue_engine` 负责 ring、
descriptor ownership、refill、reset 与 concurrency。当前实现不支持 `UVM_PASSIVE`。

scoreboard 可从环境按 queue 名获取 monitor，并连接其 analysis port：

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

analysis `write()` callback 是同步调用：在 callback 返回前，descriptor 的 owned memory
保持有效；返回后，engine 才会释放其 buffer 并退休该 descriptor。completion parsing
result 是 non-owning view；如果 scoreboard 需要跨 callback 保存它，必须在 `write()`
返回前复制所需数据。

## 在硬件适配器中实现发布取消

具体的 `gq_hw_adapter` 可以阻塞在 `publish(role, queue_id, raw_tail)` 内。对于相同的
role 与 queue ID，`disable_queue(role, queue_id)` 是正在阻塞的 `publish()` 的取消
操作；adapter 必须允许这两个 task 并发运行。每次重叠都必须准确线性化为以下一种
顺序：

- 若 `publish()` 先线性化，它的 tail update 可能已经可见，该调用必须作为不可取消的
  publish 继续到完成。稍后的 `disable_queue()` 不会追溯撤销已经可见的 update。
- 若 `disable_queue()` 先生效，尚未线性化的 publish 被取消，并且必须直接返回，不等待
  engine teardown 或 queue-memory release。从该 disable boundary 起，被取消的调用不得
  再产生新的 tail-visible side effect；尤其不能在 `disable_queue()` 返回后才使其 tail
  可见。

adapter 必须让 publish linearization、task completion 与可见的 tail side effect 保持
一致；不能一边让 hardware tail 可见，一边仍把同一次 invocation 当作可取消的 pending
work。public interface 刻意不要求单独的 `cancel_publish()` task；实现可以在
`publish()` 与 `disable_queue()` 背后使用 private cancellation helper 或 state。

disable-first 情况可以直接测试：在线性化点前阻塞 publish，同时调用 disable，然后验证
publish 返回且被取消的 tail 始终不可见。这是 cancellation 与 quiescence contract，
不是 cancellation-timeout contract。

`disable_queue()` 返回本身并不能证明对应的 SystemVerilog `publish()` task 已经
unwind。engine 会跟踪那一个确切的 in-flight task，并等待其 exact done event，之后才
能释放或复用 descriptor-owned buffer、queue ring 或任何 backing memory。adapter 不会
检查 engine 的 done event，也不会释放 host storage。反过来，`publish()` 返回是该次
invocation 的 adapter quiescence boundary：此后不得留下任何可访问 queue/backing
storage 或暴露 tail update 的 deferred work。这两项责任允许 disable 先于 task unwind
返回，同时确保 engine 不会过早释放 storage。

`publish()` 正常返回只表示 adapter call 到达 quiescence boundary；它不会自动使
sequence response 成功，也不会设置 `committed_count`。engine 必须先根据当前 epoch 与
queue lifecycle 重新校验操作，只有仍属当前生命周期的操作才向 caller 报告为已发布。
如果 runtime reset 使 in-flight user TX publish 变为 stale，即使 adapter task 正常
返回，response 仍为 `GQ_ABORTED_BY_RESET`。

## 提交 TX 任务

同一个 sequence 可表示单个 request 或 atomic batch。engine 为内部 submit transaction
接管 descriptor ownership 后，会在 publish 和 reset 的全过程继续承担 cleanup 责任；
只有 `publish()` 返回并完成 epoch/lifecycle revalidation 后，才决定 caller-visible
success。每个 TX descriptor 的 transaction buffer 都按实际 request 通过
`prepare()`/`alloc_owned()` 分配，不按 ring depth 预分配。

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

RX startup 是 one-shot 操作。engine 会 clone 提供的 profile，先 post
`initial_post_count` 个 descriptor；之后只有真实的 DUT retirement 把 posted count
降至 `low_watermark` 或以下时，才自动 refill 到 `high_watermark`。

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

第二次 startup request 返回 `GQ_RESOURCE_ERROR`。当 `restart_after_reset=1` 时，reset
recovery 会用已保存的 initial profile 重新 post；它不会接受另一次用户 startup。

## 选择轮询或中断完成模式

poll 与 IRQ mode 共用同一条有序 drain path。按前面的配置示例，在成功调用
`add_queue` 前为每个 `gq_queue_cfg` 设置 `wait_mode`、`poll_interval` 与
`completion_timeout`；ownership 转移后不要通过 `cfg.queues` 修改这些值。

IRQ mode 下，adapter 实现 `wait_irq()` 与 `ack_irq()`，timeout 同时约束 IRQ wait。
completion diagnostic 从 tail publish 返回后开始计时，对每次 oldest-outstanding episode
只报告一次；报告包含 role、queue ID、head、tail、slot、phase、ring/slot address 以及
descriptor 字节内容。

## 驱动复位与最终清理

reset assertion 和 deassertion 是由环境 reset controller 消费的 persistent event。
必须检查 boolean result，避免静默忽略重复或乱序的 edge。

```systemverilog
if (!cfg.trigger_reset_asserted())
    `uvm_fatal("RESET", "reset assertion rejected")
// Wait for DUT reset/queue-disable synchronization here.
if (!cfg.trigger_reset_deasserted())
    `uvm_fatal("RESET", "reset release rejected")
```

测试应正常 drop 最后的 run-phase objection。run phase 准备结束时，环境会 raise 自己的
objection，并按以下顺序完成自动最终清理：停止新提交并 quiesce completion activity；
对每个 queue 执行 hardware disable（或 join 已在进行的 disable）；等待 exact in-flight
`publish()` task unwind；释放 outstanding descriptor-owned buffer；最后释放 ring
backing allocation。全部 queue 都到达该边界后，环境执行一次共享 memory leak check，
再 drop 自己的 objection。该自动 finalization 在 runtime reset 后仍然安全。显式提前调用
`cleanup_and_check_leaks()` 也仍受支持；并发或重复调用会 join 同一个幂等 finalization。

```systemverilog
phase.drop_objection(this);
```

## 使用 VCS 运行

在已经加载 VCS 与 UVM license environment 的机器上运行：

```bash
make run TEST=gq_regression_test
```

仓库 helper 会把当前 working tree 内容复制到 `10.11.10.53`，进入该主机的 bash login
shell 环境，使用 VCS build 并运行一个 test，最后删除远端临时目录。`rsync` 会包含
tracked working-tree change，以及除显式排除的 `.git`、`.superpowers` 和 `build` 外
所有未排除的 untracked file；它不要求或暗示当前 tree 已 committed 或 clean。

```bash
./scripts/run_vcs_remote.sh gq_regression_test
```

完整 checked regression 使用以下八条准确命令：

```bash
./scripts/run_vcs_remote.sh gq_config_test
./scripts/run_vcs_remote.sh gq_agent_test
./scripts/run_vcs_remote.sh mailbox_desc_test
./scripts/run_vcs_remote.sh gq_submit_test
./scripts/run_vcs_remote.sh gq_completion_test
./scripts/run_vcs_remote.sh gq_refill_test
./scripts/run_vcs_remote.sh gq_reset_test
./scripts/run_vcs_remote.sh gq_regression_test
```

helper 使用的底层远端命令如下：

```bash
ssh ubuntu@10.11.10.53 \
  "cd '<temporary-copy>' && bash -lc 'bash -ic \"make run TEST=gq_regression_test\"'"
```
