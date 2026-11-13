# NV-DB-Unlock

[![GitHub stars](https://img.shields.io/github/stars/hawk1ngyang/NV-DB-Unlock?style=social)](https://github.com/hawk1ngyang/NV-DB-Unlock/stargazers)
[![Release](https://img.shields.io/github/v/release/hawk1ngyang/NV-DB-Unlock)](https://github.com/hawk1ngyang/NV-DB-Unlock/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

> ⭐ **如果这个项目帮你解开了 DB，请点右上角的 Star 支持一下！** 你的 Star 能让更多被新驱动限制功耗的人找到它。

让所有支持 **Dynamic Boost 2.0** 的 NVIDIA 独显笔记本，在 **CPU 满载（双烤）时显卡依然吃满 Dynamic Boost**。

不改 CPU 功耗、不回退显卡驱动、不开测试签名模式（不影响 ACE 等反作弊）、不刷 BIOS。

> ⚠️ **免责声明**：风险自负。本项目修改开机时加载的 ACPI 表，会提高整机功耗与温度。作者不对任何硬件损坏、数据丢失、系统无法启动或保修问题负责。使用即表示你已阅读并同意本声明。

## 原理（简版）

NVIDIA 驱动从 610 系列开始会严格执行 BIOS 中 NVPCF 设备提供的 **TPP（Total Processing Power，CPU+GPU 总功耗预算）**。
厂商 BIOS 给的 TPP 往往很小，双烤时 CPU 一吃满，总功耗超出预算，驱动就把显卡从 Dynamic Boost 最大功耗收回到基础功耗。

本项目用 OpenCore 在 Windows 启动前给 ACPI 表打一个等长补丁，把交给驱动的 TPP 固定为 256W：

```
NPCF._DSM 子功能 2:   TPPA = <变量>   →   TPPA = 0x0800  (256W)
                      TPPA = <常数>   →   TPPA = 0x0800
AML:  70 ?? ?? ?? ?? 54 50 50 41  →  70 0B 00 08 54 50 50 41 A3
      70 0B ?? ?? 54 50 50 41     →  70 0B 00 08 54 50 50 41
```

> 为什么以前“禁用 NVPCF”能解 DB，610 驱动后不行了？
> 旧驱动在没有 NVPCF 时把显卡停在最大功耗；新驱动在 NVPCF 缺失或不匹配时退回默认功耗，Dynamic Boost 整个失效。
> 所以现在只能让 NVPCF 正常工作，并把 BIOS 给它的预算改大。

只改 TPP 这一个值，显卡上限（cTGP/Dynamic Boost 最大值）不变，不会超过出厂最大功耗。

**为什么是 256W？** TPP 是“CPU+GPU 总预算”超出显卡额定功耗的部分（单位 1/8W，0x0800 = 256W）。
显卡跑满时，留给 CPU 的约为 `TPP −（显卡最大功耗 − 显卡额定功耗）`。256W 足以覆盖笔记本 CPU 与显卡同时满载，
保证驱动在任何情况下都不会因预算去压显卡。TPP 只是上限，不会让任何硬件多吃电——
CPU 实际功耗仍由厂商控制软件的 PL1/PL2、温度墙和适配器决定。

详细分析见 [docs/原理.md](docs/原理.md)。

## 适用范围

**所有支持 Dynamic Boost 2.0（带 NVPCF 设备）的 NVIDIA 独显笔记本**，不限品牌。

| 项目 | 要求 |
|---|---|
| 显卡 | RTX 30 / 40 / 50 系笔记本独显，且厂商 BIOS 开启了 Dynamic Boost 2.0 |
| CPU | Intel 或 AMD 均可（本补丁不修改 CPU 设置） |
| 系统 | Windows 10 / 11 64 位，UEFI 启动；默认需关闭安全启动（也可用下文的[安全启动模式](#安全启动模式可选)） |
| 显卡驱动 | 使用驱动自带的配套 NVPCF，不要单独替换 |

不适用：RTX 20 / GTX 16 / MX 系列、无独显笔记本、台式机（没有 Dynamic Boost 2.0）。

## 安装前检查

`0_check.bat` 会扫描本机 ACPI 表并给出结论，不兼容时安装脚本会直接拒绝，不会改动任何东西：

| 输出 | 含义 |
|---|---|
| `COMPATIBLE` | 确认 TPP 赋值就是 NVPCF 表中偏移 0x19 的 TPP 字段：只有一处，或多处（按性能模式分支）但全部位于同一个 NVPCF 方法内，可以安装 |
| `ALREADY PATCHED` | 本次开机已经打过补丁 |
| `NOT SUPPORTED YET` | 有 NVPCF，但 BIOS 代码写法不同。运行 `4_export_acpi.bat`，把 `acpi_for_issue.zip` 发到 [Issue](../../issues/new?template=compatibility.md) |
| `UNSURE` | 找到多处候选，为安全起见拒绝安装，同样请提交 ACPI 表 |
| `NOT COMPATIBLE` | 没有 NVPCF 设备，本机没有 Dynamic Boost 2.0 |

导出的 ACPI 表已自动排除含 Windows 密钥的 MSDM 表。欢迎用 [兼容性报告模板](../../issues/new?template=compatibility.md) 反馈你的机型结果。

## 前置条件

1. Windows 10/11，UEFI 启动。
2. **关闭安全启动**：开机进 BIOS（常见按键 F2 / Del / F10，以你的机型为准）→ Security 或 Boot → Secure Boot → Disabled。需要开着安全启动玩游戏的，装好后再看[安全启动模式](#安全启动模式可选)。
3. 使用**与当前显卡驱动配套的 NVPCF**（不要单独换旧版 NVPCF，否则 Dynamic Boost 完全失效，单烤也只有基础功耗）。
4. **必须关闭 BitLocker / 设备加密**，并等解密完成（设置 → 隐私和安全性 → 设备加密，或 控制面板 → BitLocker）。开着时安装脚本会直接拒绝：每次开机都经过 OpenCore，BitLocker 会认为启动链被改动而要求输入恢复密钥。
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

### 推荐：一键安装向导

下载 Release 的 zip，解压到一个固定位置（之后不要删除），**双击 `setup.bat`**：

1. 自动申请管理员权限，检查兼容性
2. 确认后自动：创建还原点 → 备份启动配置 → 安装 OpenCore（仅下一次启动生效）→ 询问是否重启
3. 重启登录后**自动弹出验证结果**；确认生效后询问是否设为永久，选 Y 即全部完成

已安装过的电脑再次运行 `setup.bat`，会显示当前状态（已生效 / 未设为永久等）并给出对应操作。

### 手动分步


下载 Release 的 zip，解压到一个固定位置（路径不要含中文更稳）。

| 步骤 | 文件 | 运行方式 | 说明 |
|---|---|---|---|
| 0 | `0_check.bat` | 双击 | 检查你的 BIOS 是否兼容。显示 `COMPATIBLE` 才继续 |
| 1 | `1_install_test.bat` | **右键 → 以管理员身份运行** | 先创建系统还原点（失败时可选择取消或输入 `YES` 风险自负继续）并备份启动配置，然后把 OpenCore 放进 EFI 分区，设为**仅下一次**启动 |
| 2 | 重启 → `2_verify.bat` | 双击 | 开机经过 OpenCore（不显示菜单，直接进 Windows）。验证显示 `PATCHED` 即生效 |
| 3 | 双烤测试 | — | 切到厂商控制软件的最高性能模式，FurMark + AIDA64 FPU，看显卡功耗 |
| 4 | `3_make_permanent.bat` | **管理员** | 再建一个还原点后，设为永久默认启动 |
| 可选 | `5_secure_boot.bat` | 双击（自动请求管理员） | 想开安全启动时用：生成本机密钥并给 OpenCore 签名，见[安全启动模式](#安全启动模式可选) |
| 适配 | `4_export_acpi.bat` | 双击 | 不兼容时导出 ACPI 表，用于提 Issue |
| 卸载 | `9_uninstall.bat` | **管理员** | 删除 OpenCore 与启动项，恢复原厂启动 |

第 1 步只生效一次：如果重启时卡住/黑屏，**长按电源键关机再开机**即回到原来的启动，什么都不会变。

OpenCore 默认**不显示启动菜单**，开机和原来一样直接进 Windows。需要看菜单时，开机时**按住 Esc** 即可调出。

## 出问题怎么恢复

按情况从上往下试，前面的能解决就不用看后面：

| 情况 | 恢复方法 |
|---|---|
| 测试启动（第 1 步后）卡住/黑屏 | 长按电源键关机 → 再开机，自动回到原来的启动 |
| 设为永久后开机卡住 | 开机时按**启动菜单键**（常见 Esc / F8 / F9 / F11 / F12，以你的机型为准）→ 选 **Windows Boot Manager** 进系统 → 管理员运行 `9_uninstall.bat` |
| 能进 Windows，但想彻底撤销 | 管理员运行 `9_uninstall.bat`（删除 OpenCore 与启动项，恢复 Windows 为第一启动项）；仍不正常时按提示执行 `bcdedit /import bcd_backup` 还原完整启动配置 |
| 系统出现其他异常 | 开始菜单搜索“创建还原点” → **系统还原** → 选择 `Before NV-DB-Unlock install` |
| Windows 完全进不去 | 连续 3 次开机时强制关机进入 **Windows 恢复环境** → 疑难解答 → 高级选项 → **系统还原**（选上面的还原点）；或在“命令提示符”中执行 `bcdboot C:\Windows` 重建启动项 |

说明：系统还原负责 Windows 本身；OpenCore 放在 EFI 分区、不在 C 盘，由 `9_uninstall.bat` / 启动菜单 / `bcdboot` 负责撤销。本项目**不会改 BIOS、不会改硬盘上的 Windows 文件**，以上任何一种方式都能完全回到原样。

排查问题时运行 `diag.bat`，把生成的 `diag.txt` 贴到 Issue。

## 安全启动模式（可选）

默认方案需要关闭安全启动。如果你玩的游戏要求开启安全启动（如部分 Vanguard / Battlefield 6），可以用**你自己的密钥**给 OpenCore 签名，再把证书加进 BIOS 的信任列表：

1. 先按上面的步骤**在安全启动关闭的状态下**装好，确认 `0_check` 显示 `0x0800`。
2. 运行 `5_secure_boot.bat`（自动请求管理员）。它会：
   - 在本机生成一把**只属于这台电脑**的签名密钥（RSA-2048，存放在 Windows 证书存储中，**不可导出**，不会生成任何私钥文件）；
   - 用它给 `OpenCore.efi` 签名，并同步到 EFI 分区；
   - 导出公钥证书 `EFI\OC\keys\ISK.cer`。
3. 把 `ISK.cer` 复制到一个 **FAT32 U 盘**。
4. 重启进 BIOS → Secure Boot → **Key Management** → **Authorized Signatures (db)** → **Append（追加）** → 选 U 盘里的 `ISK.cer`（格式选 Public Key Certificate）。
   > ⚠️ **只能选 Append / 追加**。选 Set / Update / Delete 会覆盖微软证书，导致 Windows 无法启动。
   > 如果 Key Management 里显示没有任何密钥（Setup Mode），先选 **Install Default Secure Boot Keys** 再追加。
5. **Secure Boot Control → Enabled**，F10 保存重启。
6. 运行 `0_check`，看到 `patched 0x0800` 和 `Secure Boot: on-enrolled` 即成功。

**进不了系统怎么办**：进 BIOS 把 Secure Boot 改回 Disabled 即恢复原状；若仍有问题，Key Management → **Restore Factory Keys**（恢复出厂密钥）。

注意：
- 每台电脑都要自己运行 `5_secure_boot.bat`，**不要使用别人生成的 `ISK.cer` 或签名过的 OpenCore**。
- 证书加入 db 后，这台电脑的固件会信任用这把密钥签名的任何 EFI 程序。密钥只在本机、不可导出，但能以管理员身份控制你电脑的人理论上可以用它签名，请保持系统安全。
- 以后更新本项目（OpenCore.efi 被替换）后，重新运行一次 `5_secure_boot.bat` 即可，会复用同一把密钥，不需要再进 BIOS。
- 重装 Windows 后密钥丢失：先在 BIOS 关闭安全启动，重新安装并运行 `5_secure_boot.bat`，再追加新的 `ISK.cer`（旧证书可通过 Restore Factory Keys 清除）。
- 开启安全启动后仍不能使用 BitLocker。

## 常见问题

**会影响三角洲 / 瓦罗兰特等反作弊吗？**
不开测试签名，Windows 看到的就是“原厂”ACPI 表。默认需要关闭安全启动；要求安全启动的游戏（如部分 Vanguard / Battlefield 6）请使用[安全启动模式](#安全启动模式可选)。反作弊将来是否检查信任列表里的自签名证书，无法保证。

**弹出“BitLocker 无法启用 / 无法获取加密密钥”？**
正常现象，不影响使用，C 盘也没有被加密。Windows 11 的自动设备加密需要开启安全启动才能把密钥交给 TPM，关闭安全启动后会尝试失败并弹窗。不想再看到可以关闭自动加密（管理员终端）：
`reg add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f`
注意：本方案与 BitLocker 加密不能同时使用。

**适配器功率够吗？（重要）**
原厂 TPP 预算的作用之一，是让整机功耗不超过电源适配器的供电能力。补丁把预算放宽到 256W 后，双烤时整机功耗 ≈ CPU + 显卡 + 其他部件约 35W：

| 适配器 | 建议 |
|---|---|
| 330W 及以上 | 可以使用 |
| 280W 左右 | 双烤可能超出适配器能力，出现电量下降甚至瞬间黑屏，建议在厂商软件里限制 CPU 功耗，或暂不使用 |
| 240W 及以下 | 不建议使用 |

整机持续超出适配器功率时，会由电池补电；超出过多会触发保护直接断电黑屏。

**开机停在黑色的 OpenCore 菜单（Choose the Operating System）？**
正常情况下菜单不会出现；出现说明 OpenCore 自动启动默认项失败了。常见原因：
1. **BitLocker / 设备加密没关**（最常见）→ 先在菜单里选 **Windows** 进系统，关闭 BitLocker 并等解密完成，再运行 `setup.bat`。
2. **默认项选错**：电脑上有第二块硬盘、U 盘或厂商分区（菜单里会多出 `SYSTEM`、`EFI` 等项），OpenCore 选中了它。先选 **Windows** 进系统，解压**最新版**后重新运行 `setup.bat`（v1.4 起会把 Windows Boot Manager 排在 OpenCore 之后，作为默认项）。
3. **用的是 v1.1**：那一版本来就显示菜单，请换最新版。
4. 开机时按住了 Esc。

仍然出现：运行 `diag.bat`，把 `diag.txt` 和菜单照片发到 Issue。

**以前在 OpenCore 菜单按过 Ctrl+Enter，现在补丁时有时无？**
旧版允许在菜单里“设为默认”，会在固件里新建一个直连 Windows 的启动项并排到第一，导致之后开机绕过 OpenCore。v1.3 已关闭此功能；已受影响的电脑重新运行一次 `setup.bat`，按提示设为永久即可恢复。

**不要刷改 VBIOS / 不要单独换 NVPCF**
刷“无上限功耗”的显卡固件会让显卡超过出厂上限，可能超出适配器和散热能力，且有变砖、失去保修的风险；单独换旧版 NVPCF 会让新驱动下的 DB 完全失效。本项目不需要也不建议这两种操作。

**更新显卡驱动会失效吗？** 不会，补丁在 ACPI 层，与驱动无关。

**更新 BIOS 会怎样？** 如果新 BIOS 改了这段代码，补丁不会匹配（不会出错，只是不生效）。更新后运行 `2_verify.bat` 确认。

**会改我的 SMBIOS / 激活 / 序列号吗？** 不会。OpenCore 配置为：只做 TPP 这一处 ACPI 补丁，不更新 SMBIOS、不写 NVRAM、不加载任何驱动或 kext、不改 ReBAR（`ResizeGpuBars = -1`）。见 `EFI/OC/config.plist`。

## 文件说明

```
EFI/OC/OpenCore.efi   OpenCore 1.0.8 RELEASE（官方原版，未修改）
EFI/OC/config.plist   仅含两条 TPP ACPI Patch 的最小配置（已通过 ocvalidate）
tools/acpidump.exe    Intel ACPICA 官方工具，用于检查/验证
setup.bat             一键安装向导（推荐）
oc.ps1                全部逻辑（setup / check / install / verify / permanent / uninstall / export / diag）
*.bat                 双击入口
```

## English (short)

Unlocks NVIDIA Dynamic Boost under full CPU load on any Dynamic Boost 2.0 (NVPCF) gaming laptop by patching the NVPCF `_DSM` TPP (total CPU+GPU power budget) value via OpenCore ACPI patch at boot. No driver rollback, no test-signing, no BIOS flashing. Requires Secure Boot off, or the optional Secure Boot mode (sign OpenCore with your own per-PC key and append its certificate to the firmware db). BitLocker must be off. A System Restore point is created before any change (install aborts if it fails). Run `0_check.bat` first. Use at your own risk. If it helps, please leave a ⭐!

## 致谢 / 许可

- [OpenCorePkg](https://github.com/acidanthera/OpenCorePkg) — BSD-3-Clause
- [ACPICA](https://www.intel.com/content/www/us/en/developer/topic-technology/open/acpica/overview.html) — Intel ACPICA License / BSD-3 / GPLv2
- TPP 定义参考 [NVIDIA open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules)

本项目脚本以 MIT 协议发布，第三方组件遵循各自协议，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## ⭐ 支持一下

如果它对你有用：

- 点个 **Star** ⭐，让更多人看到
- 用 [兼容性报告](../../issues/new?template=compatibility.md) 反馈你的机型结果，帮其他人确认能不能用
- 不兼容的机型欢迎提交 ACPI 表，一起把支持列表补全

## 更新日志

- **v1.4**：修复部分电脑开机停在 OpenCore 菜单（安装时把 Windows Boot Manager 排在 OpenCore 之后，保证默认启动项正确）；BitLocker / 设备加密开启时拒绝安装；支持按性能模式写了多处 TPP 的 BIOS（如部分机械革命 AMD 机型，所有赋值须在同一个 NVPCF 方法内）；新增实验性的安全启动模式 `5_secure_boot.bat`。
- **v1.3**：README 新增 BitLocker 弹窗说明与适配器功率建议；修复在 OpenCore 菜单按 Ctrl+Enter 会在固件中新建直连 Windows 的启动项并排到第一、导致之后开机绕过补丁的问题（关闭 `AllowSetDefault`）；新增一键安装向导 `setup.bat`（自动提权、检查、安装、重启后自动验证并询问设为永久）；`9_uninstall.bat` 同时清理向导的计划任务。原有分步脚本保留。
- **v1.2**：开机不再显示 OpenCore 菜单和倒计时，直接进入 Windows（需要时开机按住 Esc 调出菜单）。已安装旧版的用户：解压新版后以管理员身份运行 `1_install_test.bat` 即可更新配置，无需重新设为永久。
- **v1.1**：品牌通用；新增显卡/CPU 适用范围；安装与设为永久前自动创建并校验系统还原点，失败时列出风险并可输入 `YES` 强制继续（风险自负）；README 新增完整恢复指南；TPP 由 128W 提高到 256W（覆盖 CPU/显卡双 175W）；补丁改为掩码匹配，不再依赖特定厂商的变量名（支持 `TPPA = <任意变量>` 和 `TPPA = <常数>`）；`0_check` 额外校验 TPPA 是否为 NVPCF 表偏移 0x19 的 TPP 字段；新增 `4_export_acpi.bat` 和 Issue 模板；扫描范围扩大到 DSDT。
- **v1.0**：首个版本。
