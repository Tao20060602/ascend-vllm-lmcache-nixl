# 910B(Atlas A2)双卡测试计划

目标:在 GitCode 910B 双卡环境验证两臂可用性——A 臂(vLLM + LMCache + NIXL POSIX)、B 臂(SGLang + HiCache + NIXL POSIX),并把 910C(A3)前最后一轮非设备问题全部排掉。

## 与 910C(A3)的关键差异(先读)

| 项 | 910B(A2) | 910C(A3) |
|---|---|---|
| vllm-ascend 安装 | **pip 轮子官方支持**(源码安装为备选) | 源码安装 + 子模块 |
| 版本线 | CANN 8.5.x → v0.13.x(torch 2.7);**CANN 9.0.x → v0.30.0(torch 2.9)** | CANN 9.0.x → v0.30.0;9.2.1 → v0.32.0rc1 |
| LMCache-Ascend | 要求 vLLM ≥ v0.23.0 ⇒ **镜像 CANN 必须 ≥ 9.0.x**,8.5.x 镜像直接不可行 | 同 |
| SGLang 基准 | `v0.5.15.post1-cann9.0.0-910b`(CANN 9.0.0,Python 3.11) | CANN 9.1.0 套件(torch_npu 2.10,Python 3.12) |
| 内核包 | Ascend-cann-kernels-910b | Ascend-cann-kernels-a3 |

**选镜像原则(第 0 步就定):优先选 CANN 9.0.x 的 A2 镜像。**若只有 cann_8.5.2-py3.11-A2-arm:两个臂的现代栈都不满足(A 臂 LMCache-Ascend 需要 vllm≥0.23;B 臂 910b 路线要 CANN 9.0.0)。届时二选一:(a) 容器内升级 CANN toolkit 到 9.0.0 + `Ascend-cann-kernels-910b`(依赖宿主 HDK ≥25.5,先看 00_env_check 输出的驱动版本再决定);(b) 记录限制,只做引擎级冒烟。

**2026-11-24 更新:发现整栈预装镜像 `VLLM-Ascend-v0.26.0rc-CANN 9.1.0-arm-ssh`(GitCode 环境创建页可选)= 当前首选。**理由:vllm-ascend v0.26.0rc ≥ 0.23 满足 LMCache-Ascend 硬性下限;CANN 9.1.0 与 SGLang 当前套件对齐;厂商已对齐 vllm/torch/torch_npu/CANN,免源码编译(10_install_stack.sh 已加预装检测,自动跳过构建)。注意:rc 为候选发布版,报告如实记录;镜像内 Python 版本进环境后确认(B 臂 9.1.0 套件要 3.12)。

## 阶段划分与验收标准

### P0 环境体检与版本判读(约 30 分钟)
```bash
bash scripts/00_env_check.sh
```
- 记录:芯片型号(910B 具体子型号)、驱动/固件版本、CANN 版本、Python 版本;
- 按 CANN 分支选版本:9.0.x → 维持 `versions.env` 默认(vllm-ascend v0.30.0);8.5.x → 走上面"选镜像原则"的分支;
- 磁盘/网络核验(镜像 ≥30 GiB 下载空间、GitHub/PyPI/ModelScope 可达)。

### P1 A 臂(vLLM + LMCache + NIXL POSIX)
| 步骤 | 命令 | 验收 |
|---|---|---|
| A1 安装 | `bash scripts/10_install_stack.sh`(A2 可改用 pip 装 vllm-ascend,源码路径通用) | 版本清单落档 |
| A2 模型 | `bash scripts/20_download_model.sh`(Qwen2.5-0.5B 冒烟) | — |
| A3 单卡裸引擎 | `PROFILE=npu STAGE=l2` 前先注释 kv-transfer 验证?——不,直接 A4;裸引擎由 A3': `vllm serve` 不带 connector 手动跑一次(可选) | /health 200 |
| A4 L2 单卡 | `PROFILE=npu STAGE=l2 bash scripts/30_serve.sh && 40_smoke.sh` | 热读显著变快 + lookup 计数 ≥2 + server Stored 行 |
| A5 L3 单卡 | `PROFILE=npu STAGE=l3 ...` | 盘侧 du 出现实质字节 + 零 store failed |
| A6 重启读回探针 | 保留盘上数据,重启 server+engine 后跑 40_smoke | 记录是否命中(0.5.8 实例 tag 问题在 A2 上同样预期存在,留档即可) |
| A7 TP=2 | `TP=2 PROFILE=npu STAGE=l3 ...` | 双卡吃满、冒烟通过 |

### P2 B 臂(SGLang + HiCache + NIXL)
前提:`versions.env` 按 CANN 分支改套件(9.0.0 → torch 2.9.0 / torch_npu 2.9.0.post2 / sglang 0.5.15.post1;9.1.0 → torch 2.10.0 / torch_npu 2.10.0.post6 / sglang 主线)。装前按 SGLang Ascend 文档对应行复核。
| 步骤 | 验收 |
|---|---|
| B1 安装(conda py3.12 或镜像自带 3.11,按套件) | import + 版本清单 |
| B2 单卡裸引擎(`--attention-backend ascend`) | /health 200 |
| B3 HiCache 内存(L2) | 命中计数 + 双源核对 |
| B4 HiCache NIXL posix(L3) | 盘侧字节 + 零失败 |
| B5 重启读回探针 | 对照 lpl x86 结论(0.5.23 重启后可读,TTFT ~2.0 s)记录 ascend 行为 |
| B6 TP=2 | 双卡吃满、冒烟通过 |

### P3 收口
- 两臂结论表(同口径:计数器 + 盘侧 du 双源核对);
- 与 CPU 仿真环境结果差异清单;
- 910C 剩余差距清单(预期仅剩:A3 特有套件、TP>2 拓扑、910C 特有算子)。

## 已知风险与预案
1. **镜像 CANN 只有 8.5.x** → 按"选镜像原则"处理,不要在 8.5 上硬装现代栈;
2. **LMCache-Ascend hcomm 子模块**需与容器 CANN 匹配(官方 README 明示);
3. **nixl 轮子**:aarch64 已验证可用(POSIX 后端含在内,1.5.2);若 910B 上 import 失败,脚本自动降级源码构建;
4. **0.5.8 实例级槽位 tag**(重启不回读)预期在 A2 同样存在——只记录,不阻塞;
5. 单卡 0.5B 是功能冒烟;TP=2 与性能结论无关,性能测试等真实模型与既定负载另立任务。

## 与 CPU 仿真环境结论的关系
I/O 层与配置层(MP 模式、l2-adapter、file_size、六个坑)已在那台机器全部排掉并固化进脚本;本计划只新增 A2 设备层验证。两台机器的差异项最终并入 910C 报告。
