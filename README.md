# A 臂:vLLM + LMCache(-Ascend) + NIXL(POSIX) 在昇腾 Atlas A3(910C) 上的可用性测试

测试目标:验证 vLLM 分层 KV 缓存链路(LMCache MP 模式,NIXL POSIX 存储后端)能否在 GitCode CANN Lab 的 910C(A3)环境跑通,并记录不能跑通时的报错定位。

## 组件与版本锚点

| 组件 | 作用 | 版本来源 |
|---|---|---|
| vllm | 推理引擎本体(不含 NPU 后端) | 由 vllm-ascend 锁定,装脚本自动解析 |
| vllm-ascend | vLLM 的昇腾 NPU 平台插件 | `VLLM_ASCEND_REF`(默认 v0.30.0 稳定线,匹配 CANN 9.0.0) |
| LMCache + LMCache-Ascend | KV 缓存服务(MP 模式独立进程)+ 昇腾适配插件(公测) | `LMCACHE_REF=dev` ↔ `LMCACHE_ASCEND_REF=main` |
| NIXL | 传输/存储库,POSIX 后端 = POSIX AIO 队列实现(纯 CPU 侧文件 I/O) | `NIXL_REF`(pip 最新或源码 tag) |

所有版本集中在 `versions.env`,改版本只改该文件。**安装前必须按所选 vllm-ascend tag 的官方文档复核版本矩阵**,不同 release 的矩阵互不兼容。

## 使用顺序

```bash
bash scripts/00_env_check.sh        # 1. 体检:npu-smi、CANN、驱动、磁盘、网络(输出留档)
bash scripts/10_install_stack.sh    # 2. 安装全栈(耗时最长,可 nohup 执行)
bash scripts/20_download_model.sh   # 3. ModelScope 下载 Qwen2.5-0.5B-Instruct 冒烟模型

STAGE=l2 bash scripts/30_serve.sh   # 4a. 基线:仅 host 内存 L1
bash scripts/40_smoke.sh && bash scripts/90_teardown.sh

STAGE=l3 bash scripts/30_serve.sh   # 4b. L1 + NIXL POSIX L3(核心测试)
bash scripts/40_smoke.sh && bash scripts/90_teardown.sh

TP=2 bash scripts/30_serve.sh       # 4c. 单卡跑通后再测双卡 TP=2
```

服务终止一律用 `scripts/90_teardown.sh`(按 PID,不用 pgrep/pkill)。

## 验证口径(每阶段都要留档)

1. 两轮同前缀请求的 total_time(第 2 轮应显著变快);
2. 命中计数器:LMCache server 日志 + vllm /metrics 中 lmcache 相关项;
3. L3 阶段盘侧核对:`du -sh $HOME/lmc_storage` 与进程读字节数对照(防止"计数器为 0 但盘上有写入"之类的记账不一致,x86 侧已出现过);
4. 完整版本清单:`pip list | grep -Ei 'vllm|lmcache|nixl|torch'`(10 号脚本末尾会打印)。

## 预期的坑(测不出来时的定位方向)

- **LMCache NPU 支持是公测**:报错优先看 `torch.cuda` 调用点与 hcomm 子模块(其版本需与容器 CANN 匹配,见 LMCache-Ascend README);
- **NIXL pip 轮子**:官方轮子捆绑 CUDA 后端(NPU 机器上闲置),若 aarch64 轮子缺 POSIX 后端或 import 失败,改 `NIXL_REF=<tag>` 源码构建(POSIX AIO 只依赖 glibc);
- **双向 KV 传输**在 Ascend 上暂无官方支持,本测试用 `kv_role=kv_both` 单机复用,不涉及双向;
- **LMCache-Ascend 的 `lmcache server` 是否接受 NIXL 存储后端**未在官方 README 声明——若 l3 阶段 server 拒绝配置文件,这是本测试的核心结论,保留报错原文;
- Ascend 上建议先 `--enforce-eager`(脚本已默认),图模式作为后续性能项。

## 相关文档

- vLLM Ascend 安装:https://docs.vllm.ai/projects/ascend/zh-cn/latest/installation.html
- LMCache-Ascend 部署指南:https://docs.vllm.ai/projects/ascend/zh-cn/main/user_guide/feature_guide/lmcache_ascend_deployment.html
- LMCache-Ascend 仓库:https://github.com/LMCache/LMCache-Ascend
- LMCache NIXL 后端配置:https://docs.lmcache.ai/dev/kv_cache/storage_backends/nixl.html
- NIXL 仓库:https://github.com/ai-dynamo/nixl

## 已完成验证:CPU 仿真环境(aarch64)结论(2026-11-23)

环境:GitCode 鲲鹏 CPU 仿真环境,Ubuntu 24.04,aarch64,16 核 / 30 GiB,内核 5.10,无 NPU、无 GPFS。
组件:vllm 0.34.0+cpu(源码)、lmcache 0.5.8(PyPI)、nixl 1.5.2(PyPI aarch64 轮,含 POSIX 后端)、torch 2.14.0+cpu。

| 阶段 | 结果 | 关键数据 |
|---|---|---|
| 引擎裸启动 | ✅ | `--gpu-memory-utilization 0.30`(30 GiB 主机上 0.85 会超出可用内存) |
| L2(host 内存 offload) | ✅ | 同 ~2k token 前缀热读 0.249 s vs 冷 2.248 s(快 88.9%~95.6%,多轮复现);`lmcache_mp_lookup` 计数=2;server 侧 `Stored 2176 tokens` |
| L3(NIXL POSIX 写入) | ✅ | 26,738,688 字节真实落盘(=2176 token KV 大小,17 chunk),零 store 失败 |
| L3(重启后读回) | ❌ | 槽位文件名带实例级 tag(`obj_0_3645.bin` vs `obj_0_6a94.bin`),新实例不读旧实例数据(旧数据 26 MiB 完好留在盘上);重启后首轮为重算(5.55 s)并重新存储。与 x86 侧"重启后 L3 可读"结论不一致,属版本/配置行为差异 |
| SGLang 臂 | ❌ | 见 ascend-sglang-hicache-nixl 仓 README(sgl-kernel 无 ARM CPU 构建) |

排障顺序即踩坑清单(全部修复已固化进脚本):
1. 镜像把 `/usr/bin/python3` 软链指向损坏解释器(`_ctypes` 缺符号)→ `sudo apt-get install --reinstall python3.12-minimal`,所有安装进 venv;
2. 容器 `/dev/shm` 仅 64 MiB(vLLM 需 ≥160 MiB)→ 脚本自动重挂载 8 GiB;
3. CPU 平台 KV 池预算超配 → `--gpu-memory-utilization 0.30`;
4. **内置 `LMCacheConnectorV1` 与其声明的 `lmcache>=0.5.6` 矛盾(0.5.8 删除 `vllm_v1_adapter`)→ 提交 [vllm-project/vllm#69358](https://github.com/vllm-project/vllm/issues/69358)**;改用 `LMCacheMPConnector`;
5. extensible KV cache 平台门禁(仅 CUDA/ROCm)→ `kv_connector_extra_config: {"lmcache.mp.use_vmm_api": false}` + server `--supported-transfer-mode engine_driven`;
6. L3 配置入口:0.5.8 MP server 走 `--l2-adapter '{"type":"nixl_store","backend":"POSIX","backend_params":{"file_path":"...","use_direct_io":"false","file_size":"268435456"},"pool_size":512}'`;legacy 文档的 `nixl_*` yaml 键被静默忽略;`file_size` 必须显式给(默认每文件 1 页,页容量不足报 `Insufficient NIXL storage capacity`);`pool_size` ≥ chunk 总数。

NPU 档(`scripts/10_install_stack.sh` + `PROFILE=npu`)就绪,待 910C 环境启用;届时仅需验证 NPU 特有部分(ascend attention 后端、KV 布局),I/O 层与配置层已被本环境覆盖。
