# ROG-DB-Unlock

让华硕 ROG 游戏本在 **CPU 满载（双烤）时显卡依然吃满 Dynamic Boost**（例：RTX 4080 Laptop 双烤 150W → 175W）。

不改 CPU 功耗、不回退显卡驱动、不开测试签名模式（不影响 ACE 等反作弊）、不刷 BIOS。

> ⚠️ 风险自负。本项目修改开机时加载的 ACPI 表，会提高整机功耗与温度。作者不对任何硬件损坏、数据丢失或保修问题负责。

## 原理（简版）

新版 NVIDIA 驱动（约 2026 年起）会严格执行 BIOS 中 NVPCF 设备提供的 **TPP（Total Processing Power，CPU+GPU 总功耗预算）**。
华硕 BIOS 在增强模式下只给 TPP = 额定 TGP + 55W，双烤时 CPU 一吃满，驱动就把显卡从 175W 收回到 150W。

本项目用 OpenCore 在 Windows 启动前给 ACPI 表打一个 9 字节的补丁：

```
NPCF._DSM 子功能 2:   TPPA = ATPP      →   TPPA = 0x0400  (128W)
AML:                  70 41 54 50 50 54 50 50 41   →   70 0B 00 04 54 50 50 41 A3
```

只改 TPP 这一个值，显卡上限（cTGP/Dynamic Boost 最大值）不变，不会超过出厂最大功耗。
详细分析见 [docs/原理.md](docs/原理.md)。

## 已测试机型

| 机型 | BIOS | 显卡驱动 | 结果 |
|---|---|---|---|
| ROG Strix SCAR 16 2023 (G634JZ, i9-13980HX + RTX 4080) | — | 621.14 | 双烤 150W → 175W ✅ |

欢迎提交 Issue / PR 补充其他机型（附上 `0_check.bat` 的输出）。

## 前置条件

1. Windows 10/11，UEFI 启动。
2. **关闭安全启动**：BIOS(F2) → Security → Secure Boot Control → Disabled。
3. 使用**与当前显卡驱动配套的 NVPCF**（不要单独换旧版 NVPCF，否则 Dynamic Boost 完全失效，单烤也只有基础功耗）。
4. 如开启了 BitLocker，先准备好恢复密钥（aka.ms/myrecoverykey）。脚本会自动暂停保护，但以防万一。

## 使用

下载 Release 的 zip，解压到一个固定位置（路径不要含中文更稳）。

| 步骤 | 文件 | 运行方式 | 说明 |
|---|---|---|---|
| 0 | `0_check.bat` | 双击 | 检查你的 BIOS 是否兼容。显示 `COMPATIBLE` 才继续 |
| 1 | `1_install_test.bat` | **右键 → 以管理员身份运行** | 备份启动配置、创建还原点、把 OpenCore 放进 EFI 分区，设为**仅下一次**启动 |
| 2 | 重启 → `2_verify.bat` | 双击 | 出现 OpenCore 菜单，3 秒后自动进 Windows。验证显示 `PATCHED` 即生效 |
| 3 | 双烤测试 | — | 奥创切增强/手动模式，FurMark + AIDA64 FPU，看显卡功耗 |
| 4 | `3_make_permanent.bat` | **管理员** | 确认没问题后设为永久默认启动 |
| 卸载 | `9_uninstall.bat` | **管理员** | 删除 OpenCore 与启动项，恢复原厂启动 |

第 1 步只生效一次：如果重启时卡住/黑屏，**长按电源键关机再开机**即回到原来的启动，什么都不会变。

排查问题时运行 `diag.bat`，把生成的 `diag.txt` 贴到 Issue。

## 常见问题

**会影响三角洲 / 瓦罗兰特等反作弊吗？**
不开测试签名，Windows 看到的就是“原厂”ACPI 表。但需要关闭安全启动——要求安全启动的游戏（如部分 Vanguard / Battlefield 6 等）无法使用本方案。

**更新显卡驱动会失效吗？** 不会，补丁在 ACPI 层，与驱动无关。

**更新 BIOS 会怎样？** 如果新 BIOS 改了这段代码，补丁不会匹配（不会出错，只是不生效）。更新后运行 `2_verify.bat` 确认。

**会改我的 SMBIOS / 激活 / 序列号吗？** 不会。OpenCore 配置为：只做这一个 ACPI 补丁，不更新 SMBIOS、不写 NVRAM、不加载任何驱动或 kext、不改 ReBAR（`ResizeGpuBars = -1`）。见 `EFI/OC/config.plist`。

## 文件说明

```
EFI/OC/OpenCore.efi   OpenCore 1.0.8 RELEASE（官方原版，未修改）
EFI/OC/config.plist   仅含一条 ACPI Patch 的最小配置（已通过 ocvalidate）
tools/acpidump.exe    Intel ACPICA 官方工具，用于检查/验证
oc.ps1                全部逻辑（check / install / verify / permanent / uninstall / diag）
*.bat                 双击入口
```

## English (short)

Unlocks NVIDIA Dynamic Boost under full CPU load on ASUS ROG laptops by patching the NVPCF `_DSM` TPP (total CPU+GPU power budget) value via OpenCore ACPI patch at boot. No driver rollback, no test-signing, no BIOS flashing. Requires Secure Boot off. Run `0_check.bat` first. Use at your own risk.

## 致谢 / 许可

- [OpenCorePkg](https://github.com/acidanthera/OpenCorePkg) — BSD-3-Clause
- [ACPICA](https://www.intel.com/content/www/us/en/developer/topic-technology/open/acpica/overview.html) — Intel ACPICA License / BSD-3 / GPLv2
- TPP 定义参考 [NVIDIA open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules)
- 华硕 ACPI 接口参考 [G-Helper](https://github.com/seerge/g-helper)

本项目脚本以 MIT 协议发布，第三方组件遵循各自协议，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
