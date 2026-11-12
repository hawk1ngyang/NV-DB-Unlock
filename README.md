# NV-DB-Unlock

> 原名 ROG-DB-Unlock。旧链接会自动跳转。

[![GitHub stars](https://img.shields.io/github/stars/hawk1ngyang/NV-DB-Unlock?style=social)](https://github.com/hawk1ngyang/NV-DB-Unlock/stargazers)
[![Release](https://img.shields.io/github/v/release/hawk1ngyang/NV-DB-Unlock)](https://github.com/hawk1ngyang/NV-DB-Unlock/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

> ⭐ **如果这个项目帮你解开了 DB，请点右上角的 Star 支持一下！** 你的 Star 能让更多被 150W 困扰的人找到它。

让 NVIDIA 独显游戏本（各品牌通用结构，已在华硕 ROG 实测）在 **CPU 满载（双烤）时显卡依然吃满 Dynamic Boost**（例：RTX 4080 Laptop 双烤 150W → 175W）。

不改 CPU 功耗、不回退显卡驱动、不开测试签名模式（不影响 ACE 等反作弊）、不刷 BIOS。

> ⚠️ **免责声明**：风险自负。本项目修改开机时加载的 ACPI 表，会提高整机功耗与温度。作者不对任何硬件损坏、数据丢失、系统无法启动或保修问题负责。使用即表示你已阅读并同意本声明。

## 原理（简版）

NVIDIA 驱动从 610 系列开始会严格执行 BIOS 中 NVPCF 设备提供的 **TPP（Total Processing Power，CPU+GPU 总功耗预算）**。
以华硕为例，BIOS 在增强模式下只给 TPP = 额定 TGP + 55W，双烤时 CPU 一吃满，驱动就把显卡从 175W 收回到 150W。

本项目用 OpenCore 在 Windows 启动前给 ACPI 表打一个等长补丁，把交给驱动的 TPP 固定为 256W：

```
NPCF._DSM 子功能 2:   TPPA = <任意4字母变量>   →   TPPA = 0x0800  (256W)   例: 华硕 TPPA = ATPP
                      TPPA = <常数>            →   TPPA = 0x0800
AML:  70 ?? ?? ?? ?? 54 50 50 41  →  70 0B 00 08 54 50 50 41 A3
      70 0B ?? ?? 54 50 50 41     →  70 0B 00 08 54 50 50 41
```

> 为什么以前“禁用 NVPCF”能解 DB，610 驱动后不行了？
> 旧驱动在没有 NVPCF 时把显卡停在最大功耗；新驱动在 NVPCF 缺失/不匹配时退回默认功耗（实测单烤也只有 150W）。
> 所以现在只能让 NVPCF 正常工作，并把 BIOS 给它的预算改大。

只改 TPP 这一个值，显卡上限（cTGP/Dynamic Boost 最大值）不变，不会超过出厂最大功耗。

**为什么是 256W？** TPP 是“CPU+GPU 总预算”超出显卡额定功耗的部分（单位 1/8W，0x0800 = 256W）。
显卡跑满 175W 时，留给 CPU 的约为 `TPP − 25W`。256W 足够覆盖 CPU 175W + 显卡 175W，
保证驱动在任何情况下都不会因预算去压显卡。TPP 只是上限，不会让任何硬件多吃电——
CPU 实际功耗仍由奥创/G-Helper 的 PL1/PL2、温度墙和适配器决定。

| TPP | 显卡 175W 时 CPU 可用 |
|---|---|
| 55W（原厂增强） | ~30W |
| 65W（原厂手动） | ~40W |
| **256W（本补丁）** | **~230W（不再是瓶颈）** |
详细分析见 [docs/原理.md](docs/原理.md)。

## 已测试机型

| 机型 | BIOS | 显卡驱动 | 结果 |
|---|---|---|---|
| ROG Strix SCAR 16 2023 (G634JZ, i9-13980HX + RTX 4080) | — | 621.14 | 双烤 150W → 175W ✅ |

## 适用范围

### 显卡

| 显卡 | Dynamic Boost | 适用性 |
|---|---|---|
| **RTX 40 系笔记本**（4050 / 4060 / 4070 / 4080 / 4090 Laptop） | DB 2.0（NVPCF） | ✅ 适用，**已实测：RTX 4080 Laptop** |
| RTX 30 系笔记本（3050 / 3060 / 3070 / 3080 / 3080 Ti Laptop） | DB 2.0（NVPCF） | ⚠️ 理论适用，未实测 |
| RTX 50 系笔记本 | DB 2.0（NVPCF） | ⚠️ 理论适用，未实测 |
| RTX 20 系 / GTX 16 系笔记本 | 无或 DB 1.0（无 NVPCF） | ❌ 不适用 |
| MX 系列、无独显笔记本 | 无 | ❌ 不适用 |
| 台式机显卡 | 无 Dynamic Boost | ❌ 不适用（台式机本来就没有这个限制） |

另外要求厂商 BIOS 开启了 Dynamic Boost。部分轻薄本或低功耗型号的厂商关闭了 DB，即使是 RTX 40 系也不适用。
`0_check.bat` 会自动检测：没有 NVPCF 设备（`NVDA0820`）的机器直接显示 `NOT COMPATIBLE`。

### CPU

| CPU | 适用性 |
|---|---|
| Intel 第 11–14 代酷睿 H/HX、酷睿 Ultra H/HX | ✅ 适用，**已实测：i9-13980HX** |
| AMD 锐龙 5000 / 6000 / 7000 / 8000 / AI 系列 H/HS/HX | ⚠️ 理论适用，未实测（NVPCF 规范同时支持 Intel 与 AMD） |

本补丁只调整 NVIDIA 驱动的功耗预算，**不修改 CPU 设置**。CPU 实际能跑到多少瓦，仍由厂商控制软件（奥创 / Legion Space / OMEN Gaming Hub / MSI Center 等）的 PL1/PL2、温度墙和电源适配器决定。

### 系统

- Windows 10 / 11 64 位，UEFI 启动（不支持 Legacy/CSM）
- 显卡驱动：已在 621.14 实测；主要针对 610 以后“禁用 NVPCF 失效”的新驱动，旧驱动理论上同样适用
- 需要关闭安全启动

## 其他品牌能用吗？

原理对所有 Dynamic Boost 2.0 笔记本相同（接口和数据格式由 NVIDIA 统一规定），区别只在各厂商 BIOS 的代码写法。
`0_check.bat` 会自动判断：

| 输出 | 含义 |
|---|---|
| `COMPATIBLE` | 找到唯一一处 TPP 赋值，且确认它就是 NVPCF 表中偏移 0x19 的 TPP 字段，可以安装 |
| `NOT SUPPORTED YET` | 有 NVPCF，但代码写法不同。运行 `4_export_acpi.bat`，把 `acpi_for_issue.zip` 发到 [Issue](../../issues/new?template=compatibility.md)，按同样思路适配 |
| `UNSURE` | 找到多处候选，为安全起见拒绝安装，同样请提交 ACPI 表 |
| `NOT COMPATIBLE` | 没有 NVPCF 设备，本机没有 Dynamic Boost 2.0 |

不兼容时安装脚本会直接拒绝，不会改动任何东西。导出的 ACPI 表已自动排除含 Windows 密钥的 MSDM 表。

欢迎用 [兼容性报告模板](../../issues/new?template=compatibility.md) 提交你的机型结果。

## 前置条件

1. Windows 10/11，UEFI 启动。
2. **关闭安全启动**：开机进 BIOS（华硕/微星多为 F2 或 Del，联想多为 F2 或 Fn+F2，惠普多为 F10，戴尔多为 F2）→ Security 或 Boot → Secure Boot → Disabled。
3. 使用**与当前显卡驱动配套的 NVPCF**（不要单独换旧版 NVPCF，否则 Dynamic Boost 完全失效，单烤也只有基础功耗）。
4. 如开启了 BitLocker，先准备好恢复密钥（aka.ms/myrecoverykey）。脚本会自动暂停保护，但以防万一。
5. **系统保护（还原点）**。安装和设为永久前，脚本都会先创建系统还原点，并读回确认确实创建成功。
   如果创建失败，建议先打开系统保护再重试：开始菜单搜索“创建还原点” → 选中 C 盘 → 配置 → 启用系统保护（建议 5%）→ 确定。
   确实无法开启时，脚本会列出风险并让你选择：**输入大写 `YES` 强制继续**，或任意其他输入取消（取消则不做任何修改）。

> ⚠️ **强制继续（不创建还原点）的后果——由使用者自行承担，作者不负任何责任：**
> 1. 出问题时**无法用“系统还原”一键回退**。
> 2. 如果开机异常（卡在 OpenCore、黑屏、找不到启动项），只能按下方“出问题怎么恢复”手动修复：启动菜单选 Windows Boot Manager → 运行 `9_uninstall.bat`，或在 Windows 恢复环境执行 `bcdboot C:\Windows`。
> 3. 如果手动修复也失败，**可能需要重装 Windows，未备份的数据可能丢失**。
> 4. 功耗提高会带来更高温度，高负载下电池可能放电，由此产生的后果自负。
>
> 选择强制继续时，脚本会在本目录生成 `forced_without_restore_point.txt` 记录该选择。

## 使用

下载 Release 的 zip，解压到一个固定位置（路径不要含中文更稳）。

| 步骤 | 文件 | 运行方式 | 说明 |
|---|---|---|---|
| 0 | `0_check.bat` | 双击 | 检查你的 BIOS 是否兼容。显示 `COMPATIBLE` 才继续 |
| 1 | `1_install_test.bat` | **右键 → 以管理员身份运行** | 先创建系统还原点（失败时可选择取消或输入 `YES` 风险自负继续）并备份启动配置，然后把 OpenCore 放进 EFI 分区，设为**仅下一次**启动 |
| 2 | 重启 → `2_verify.bat` | 双击 | 出现 OpenCore 菜单，3 秒后自动进 Windows。验证显示 `PATCHED` 即生效 |
| 3 | 双烤测试 | — | 切到厂商控制软件的最高性能模式（如华硕奥创增强/手动），FurMark + AIDA64 FPU，看显卡功耗 |
| 4 | `3_make_permanent.bat` | **管理员** | 再建一个还原点后，设为永久默认启动 |
| 适配 | `4_export_acpi.bat` | 双击 | 不兼容时导出 ACPI 表，用于提 Issue |
| 卸载 | `9_uninstall.bat` | **管理员** | 删除 OpenCore 与启动项，恢复原厂启动 |

第 1 步只生效一次：如果重启时卡住/黑屏，**长按电源键关机再开机**即回到原来的启动，什么都不会变。

## 出问题怎么恢复

按情况从上往下试，前面的能解决就不用看后面：

| 情况 | 恢复方法 |
|---|---|
| 测试启动（第 1 步后）卡住/黑屏 | 长按电源键关机 → 再开机，自动回到原来的启动 |
| 设为永久后开机卡在 OpenCore | 开机时按**启动菜单键**（华硕 Esc 或 F8，联想 F12，惠普 F9，戴尔 F12，微星 F11）→ 选 **Windows Boot Manager** 进系统 → 管理员运行 `9_uninstall.bat` |
| 能进 Windows，但想彻底撤销 | 管理员运行 `9_uninstall.bat`（删除 OpenCore 与启动项，恢复 Windows 为第一启动项）；仍不正常时按提示执行 `bcdedit /import bcd_backup` 还原完整启动配置 |
| 系统出现其他异常 | 开始菜单搜索“创建还原点” → **系统还原** → 选择 `Before NV-DB-Unlock install` |
| Windows 完全进不去 | 连续 3 次开机时强制关机进入 **Windows 恢复环境** → 疑难解答 → 高级选项 → **系统还原**（选上面的还原点）；或在“命令提示符”中执行 `bcdboot C:\Windows` 重建启动项 |

说明：系统还原负责 Windows 本身；OpenCore 放在 EFI 分区、不在 C 盘，由 `9_uninstall.bat` / 启动菜单 / `bcdboot` 负责撤销。本项目**不会改 BIOS、不会改硬盘上的 Windows 文件**，以上任何一种方式都能完全回到原样。

排查问题时运行 `diag.bat`，把生成的 `diag.txt` 贴到 Issue。

## 常见问题

**会影响三角洲 / 瓦罗兰特等反作弊吗？**
不开测试签名，Windows 看到的就是“原厂”ACPI 表。但需要关闭安全启动——要求安全启动的游戏（如部分 Vanguard / Battlefield 6 等）无法使用本方案。

**更新显卡驱动会失效吗？** 不会，补丁在 ACPI 层，与驱动无关。

**更新 BIOS 会怎样？** 如果新 BIOS 改了这段代码，补丁不会匹配（不会出错，只是不生效）。更新后运行 `2_verify.bat` 确认。

**会改我的 SMBIOS / 激活 / 序列号吗？** 不会。OpenCore 配置为：只做 TPP 这一处 ACPI 补丁，不更新 SMBIOS、不写 NVRAM、不加载任何驱动或 kext、不改 ReBAR（`ResizeGpuBars = -1`）。见 `EFI/OC/config.plist`。

## 文件说明

```
EFI/OC/OpenCore.efi   OpenCore 1.0.8 RELEASE（官方原版，未修改）
EFI/OC/config.plist   仅含两条 TPP ACPI Patch 的最小配置（已通过 ocvalidate）
tools/acpidump.exe    Intel ACPICA 官方工具，用于检查/验证
oc.ps1                全部逻辑（check / install / verify / permanent / uninstall / export / diag）
*.bat                 双击入口
```

## English (short)

Unlocks NVIDIA Dynamic Boost under full CPU load on NVIDIA gaming laptops (verified on ASUS ROG; vendor-agnostic matching) by patching the NVPCF `_DSM` TPP (total CPU+GPU power budget) value via OpenCore ACPI patch at boot. No driver rollback, no test-signing, no BIOS flashing. Requires Secure Boot off. A System Restore point is created before any change (install aborts if it fails). Run `0_check.bat` first. Use at your own risk. If it helps, please leave a ⭐!

## 致谢 / 许可

- [OpenCorePkg](https://github.com/acidanthera/OpenCorePkg) — BSD-3-Clause
- [ACPICA](https://www.intel.com/content/www/us/en/developer/topic-technology/open/acpica/overview.html) — Intel ACPICA License / BSD-3 / GPLv2
- TPP 定义参考 [NVIDIA open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules)
- 华硕 ACPI 接口参考 [G-Helper](https://github.com/seerge/g-helper)

本项目脚本以 MIT 协议发布，第三方组件遵循各自协议，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## ⭐ 支持一下

如果它对你有用：

- 点个 **Star** ⭐，让更多人看到
- 用 [兼容性报告](../../issues/new?template=compatibility.md) 反馈你的机型结果，帮其他人确认能不能用
- 不兼容的机型欢迎提交 ACPI 表，一起把支持列表补全

## 更新日志

- **v1.1**：项目更名为 NV-DB-Unlock（品牌通用）；新增显卡/CPU 适用范围；安装与设为永久前自动创建并校验系统还原点，失败时列出风险并可输入 `YES` 强制继续（风险自负）；README 新增完整恢复指南；TPP 由 128W 提高到 256W（覆盖 CPU/显卡双 175W）；补丁改为掩码匹配，不再依赖华硕的变量名（支持 `TPPA = <任意变量>` 和 `TPPA = <常数>`）；`0_check` 额外校验 TPPA 是否为 NVPCF 表偏移 0x19 的 TPP 字段；新增 `4_export_acpi.bat` 和 Issue 模板；扫描范围扩大到 DSDT。
- **v1.0**：首个版本，ROG Strix SCAR 16 2023 实测。
