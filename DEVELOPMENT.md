# 开发参考（DEVELOPMENT.md）

> 本文件记录开发 `vray_material_replacer.ms` 过程中的**关键技术决策、架构说明、踩过的坑、已验证的解决方案与查证来源**。
> 目的：以后遇到类似问题（MaxScript 材质操作、V-Ray 属性名、MD→HTML 报告等）能直接查、少走弯路。
> 按 knowledge-base `模板库/单项目规范` 组织：项目概览 → 架构说明 → 关键问题与方案（一坑一篇）。

---

## 1. 项目概览

**做什么**：3ds Max 材质工具箱——把场景 V-Ray 材质批量转成 Standard / Physical，支持全场景统一转换、转换前自动备份可恢复、程序贴图烘焙（FBX 兼容）、导出材质构成 MD（AI → HTML 报告）。

**技术选型**：MaxScript 单文件（为什么不是 C++ SDK）：

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| **MaxScript** | 内置、零依赖、复制粘贴即跑、改完立刻见效、稳定性高 | 性能不如 C++、语法古老 | ✅ 选它，符合「越简单越稳定」 |
| C++ SDK / Max 插件 | 性能好、能做复杂 UI | 需编译、需 VS 环境、部署麻烦、易踩 ABI 坑 | ❌ 过度工程，否决 |

---

## 2. 架构说明

单文件 911 行（2026-08-15），按注释分区：

| 区段 | 行号（约） | 职责 |
|---|---|---|
| 共享工具函数 | 24-110 | `pad2`/`colorToHex`/`mapFilename`/`nowStr`/`cleanName`/`joinStr`/`recurseMats`/`collectAllMaterials`/`buildMatObjectMap`/`getMatObjects`（顶层块，彼此可见） |
| 材质备份/恢复 | 167-188 | `backupSceneMats`（saveTempMaterialLibrary sceneMaterials）/ `restoreSceneMats`（SceneConverter.OverwriteFromMaterialLibrary）+ `global gBackupPath` |
| 程序贴图烘焙 | 190-264 | `collectProcMaps`（防环收集）/ `bakeMapToFile` / `bakeAndReplace` / `bakeOnly`（renderMap API） |
| 导出三阶段 | 266-494 | `buildInfos`（收集 MatInfo 数组）/ `renderMD`（拼 MD 字符串）/ `writeMDFile`（写盘）/ `exportDoc`（薄协调层） |
| 面板一：材质替换 | 496-748 | `rdoTarget` 单选 / `chkMaps` / `chkBitmap` / `chkAll`（统一转换）/ `chkBackup` / `btnGo` / `btnCount` / `btnRestore`；`convBitmap` / `setPhysMap` / `vrMtlToStandard` / `vrMtlToPhysical` / `stdToPhysical` / `physToStandard` / `vrLightToStandard` / `vrGenericToStandard` / `convertMaterial` |
| 面板三：导出 MD | 750-806 | `edtPath` / `chkObjs` / `chkMaps` / `chkParams` / `btnCopy` / `btnGo`（catch 输出完整异常+调用栈） |
| 面板二：程序贴图烘焙 | 808-876 | `edtDir` / `ddlSize` / `chkReplace` / `btnGo` |
| 主窗口 | 878-884 | `newRolloutFloater`，addRollout 顺序 ①替换→②烘焙→③导出 |

**核心设计原则**（规避 MAXScript 无闭包限制）：
- 所有跨函数数据一律**参数/返回值传递**，不共享局部变量
- 辅助函数全部放**顶层块**（互相可见），不嵌套定义
- 属性访问全部 `try/catch` + `hasProperty` 防御

---

## 3. 关键问题与方案（一坑一篇）

### 问题：MAXScript 没有闭包，嵌套函数引用外层局部编译报错

**TL;DR**：具名 `fn` 写在另一函数体内会在外层作用域编译，访问不到外层局部变量 → 报「此处不允许使用外部局部变量引用」。

- 问题：exportDoc 内曾定义 `fn L s = ( ... s ... )` 引用外层 `ss`
- 根因：MAXScript 无词法闭包（官方文档 "The scope of the function name variable is the current MAXScript scope"）
- 解决：删除嵌套函数，改顶层块级函数 + 参数/返回值传递
- 预防：函数体内**永远不要**定义依赖外层局部的 fn

### 问题：`local fn` 组合语法不存在

**TL;DR**：MAXScript 无 `local fn name = ...`，块内 `fn` 天然局部。

- 问题：`local fn lPad2 s = (...)` 报「位于 function，需要 name」
- 根因：局部变量定义（`local <name>`）与局部函数定义（`fn <name>`）是两类独立语法
- 解决：去掉 `local` 前缀
- 预防：写辅助函数直接 `fn`，不联想其他语言的 `local function`

### 问题：想当然的函数名（bit.char / trim / ->）

**TL;DR**：`bit.char` 不存在（用 `bit.intAsChar`）；`trim` 不存在（用 `trimLeft`/`trimRight`）；`->` 不存在（用 `=`）。

- 问题：`bit.char 13` 报「未知属性 char 位于 bit」；`trim s` 报「trim 未定义」；`fn s -> (...)` 报语法错误
- 根因：凭直觉使用其他语言习惯的函数名，MAXScript 无这些 API
- 解决：查官方文档逐一替换
- 预防：**任何不熟悉的 API 先查官方文档**，不靠记忆/猜测（本仓库已踩 3 次同款坑）

### 问题：核心接口 SceneConverter 不能实例化

**TL;DR**：`SceneConverter()` 是解析期语法错误（「位于 .，需要<因子>」），直接点号调用 `SceneConverter.OverwriteFromMaterialLibrary path`。

- 问题：`try ( local sc = SceneConverter(); sc.OverwriteFromMaterialLibrary path )` 整个脚本加载即崩
- 根因：核心接口（Core Interface）不是类，官方文档格式就是 `SceneConverter.MethodName args`
- 解决：去掉实例化，直接点号调用；`try/catch` 包运行时失败
- 预防：MAXScript 核心接口（SceneConverter 等）一律直接当全局对象点号调用

### 问题：maxFileName 不含路径

**TL;DR**：`maxFileName` 只含文件名，`getFilenamePath maxFileName` 返回空 → 拼出相对路径；路径用 `maxFilePath`。

- 问题：烘焙输出目录显示 `_baked_maps`（无盘符）报「输出目录不可用」
- 根因：用错变量（官方：`maxFileName`=文件名，`maxFilePath`=路径含尾斜杠）
- 解决：三处（备份/导出/烘焙目录）改用 `maxFilePath`
- 预防：完整路径 = `maxFilePath + maxFileName`

### 问题：BitmapTexture 没有 enabled 属性

**TL;DR**：`tm.enabled` 对 BitmapTexture 不存在 → 报告「启用」列全"否"误导用户。

- 问题：导出报告 178 张贴图全显示「未启用」
- 根因：官方 BitmapTexture 属性表无 `enabled`；启用状态在材质槽位属性
- 解决：反查材质属性找到引用本贴图的槽位（diffuseMap/base_color_map）→ 读 `<slot>MapEnable` 或 `<slot>_map_enabled`
- 预防：报告类读取先确认属性存在，读取失败按 true（已连接）处理

### 问题：程序贴图收集可能死循环

**TL;DR**：循环引用贴图树（A 含 A）会无限入栈。

- 问题：`collectProcMaps` 内层贴图无条件入栈
- 根因：缺少 seen 去重（子贴图收集有去重但入栈没有）
- 解决：入栈条件加 `and (findItem seen tm) == 0`
- 预防：任何递归/栈遍历先想环

### 问题：for...where... 嵌套过滤引用外层变量报 undefined

**TL;DR**：`for o where ... do ( for pair where o.material ... )` 内层 where 引用外层 `o` → undefined。

- 问题：「调用需要函数或类，得到的是: undefined」
- 根因：MAXScript `where` 子句在循环开始时对过滤表达式单独求值，外层循环变量不可见
- 解决：统一朴素 `for + if` 写法
- 预防：避免嵌套 `for...where...`，用 `if` 替代

### 问题：ArrayParameter 伪材质导致遍历 undefined

**TL;DR**：`getPropNames` 对非材质对象（ArrayParameter）返回 undefined，`for p in props` 崩。

- 问题：「没有与以下项对应的 map 函数 undefined」
- 根因：collectAllMaterials 收集到非材质对象（9 个 undefined 的数组）
- 解决：`if props == undefined do props = #()` 防御
- 预防：第三方对象遍历前确认返回值

---

## 4. 查证与交叉验证来源

所有属性名都经过**多源交叉验证**，不要凭记忆改：

1. **Autodesk 官方 MAXScript 帮助** — Standard / Physical 材质属性表、`getClassInstances`、`getSub*Mtl`、`getSub*Texmap` 系列 API、`SceneConverter` 核心接口、`saveTempMaterialLibrary`
2. **Chaos（V-Ray）官方文档 + 官方论坛** — `VRayMtl` / `VRayLightMtl` / 各类包裹材质的参数与 MaxScript 属性名、`.HDRIMapName`
3. **Autodesk 3ds Max 官方编程论坛** — `denisT.MaxDoctor`、`Swordslayer`、`BOBO` 关于 `getClassInstances` + `replaceInstances`、`saveTempMaterialLibrary sceneMaterials` 的成熟写法
4. **ScriptSpot / Blender Market** — V-Ray to Standard Converter 实战脚本、Max↔Blender 桥接工具调研
5. **Khronos 官方** — glTF 导出、EXT_mesh_gpu_instancing

> 🔑 经验：**V-Ray 属性名在不同大版本基本一致，但 Physical 材质槽名随 Max 版本漂移**；凡涉及 Physical 一律「两种命名都试 + `try/catch` 兜底」。

---

## 5. 版本兼容性矩阵

| 维度 | 最低要求 | 备注 |
|------|----------|------|
| 3ds Max | 任意较新版本 | `getClassInstances` / `replaceInstances` 长期稳定 |
| Physical 材质 | 3ds Max 2017+ | `canPhysical` 类存在性探测，老版本自动退回 Standard |
| SceneConverter 恢复 | 3ds Max 2017+ | 备份用 saveTempMaterialLibrary（更老也兼容） |
| V-Ray | 不强制安装 | 替换逻辑读的是场景已有材质数据 |
| dotNet 剪贴板 | Max 默认带 | 精简环境可能无 → 已做回退到日志显示 |
| Blender（桥接） | 5.2（本机） | glTF/GLB 导出 + bpy 刷新脚本（规划中） |

---

## 6. 已知限制与取舍（如实记录）

- **V-Ray 专属参数被丢弃**：反射细分 / 折射细分 / Fresnel / SSS 在标准/物理材质无对应项 → 丢弃。取舍是「能正常打开、无 V-Ray 依赖」而非「渲染一致」。
- **Standard 目标无 metalness**：3ds Max 材质系统硬限制，金属度只能选 Physical 目标才保留。
- **替换不可逆（除非用备份）**：转换前勾选「自动备份」才有 .mat 可恢复；恢复靠同名覆盖，改名后匹配不上。
- **VRayLightMtl 强度**不精确映射标准自发光强度（无 HDR 级别）。
- **程序贴图**（VRayDirt/VRayColor/falloff 等）FBX 不支持 → 需先用面板二烘焙成位图。

---

## 7. 待办 / 后续可增强

- [x] 只统计不替换的预览按钮（btnCount，已实现并扩展为三类材质统计）
- [x] 转换前自动备份 + 一键恢复（chkBackup / btnRestore，已实现）
- [x] 全场景统一转换（chkAll，已实现）
- [ ] Max → Blender 桥接：一键导出 GLB + Blender 刷新脚本（bpy）
- [ ] 把 VRayDirt / VRayColor 烘焙流程做成面板二默认勾选
- [ ] 包成 macroScript 安装到工具栏
- [ ] 报告「启用」列在贴图禁用时给出更细的区分（当前按已连接处理）
