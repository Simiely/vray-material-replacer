# CHANGELOG

所有显著变更都会记录在此文件。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [3.2.0] - 2026-08-15

### 新增
- **可逆转换**：转换前自动备份场景材质为 `.mat`（`saveTempMaterialLibrary sceneMaterials`），新增「从备份恢复原材质」按钮（`SceneConverter.OverwriteFromMaterialLibrary` 同名覆盖还原），不满意可一键撤销转换
- **全场景统一转换**：新增「统一转换所有材质」勾选，勾选后 Standard ↔ Physical 双向互转（`stdToPhysical` / `physToStandard`），配合现有 VRay* 转换可一键把所有材质统一为目标类型；按钮文案随勾选联动
- **程序贴图烘焙面板**（面板二，排位提前）：用官方 `renderMap` API 把 3ds Max 程序贴图（falloff/VRayColor/Color_Correction 等）烘焙成位图并可选替换原槽位，解决 FBX 导出后其他软件不识别程序贴图的问题；分辨率 512/1024/2048 可选
- **Physical 目标增强**：数值参数迁移（金属度/粗糙度/IOR/反射色/折射/自发光/漫反射粗糙度）+ 凹凸贴图槽迁移
- **Standard 目标增强**：光泽度/IOR/自发光/透明度参数迁移

### 修复
- **P-01**：`collectProcMaps` 程序贴图入栈缺 `seen` 去重，循环引用贴图树（A 含 A）会无限入栈卡死 3ds Max
- **P-02**：导出报告「启用」列永远显示"否"——`tm.enabled` 对 BitmapTexture 不存在（官方属性表无此属性），改为反查材质槽位启用开关（`<slot>MapEnable` / `<slot>_map_enabled`）
- **P-03**：烘焙文件名同分内同名实例互相覆盖，后缀加随机数（`_100-999`）
- **P-04**：恢复失败时提示 `loadMaterialLibrary` 手动替代方案
- **P-06**：转换循环失败不再静默吞掉，`failCount` 统计并在日志显示「⚠ 失败 N 个」
- **路径 bug**：`getFilenamePath maxFileName` 返回空（maxFileName 只含文件名），三处（备份/导出/烘焙目录）改用 `maxFilePath`
- **语法 bug**：`SceneConverter()` 实例化写法是解析期语法错误，改为直接点号调用 `SceneConverter.OverwriteFromMaterialLibrary`
- 面板顺序重排：① 替换 → ② 烘焙 → ③ 导出

## [3.1.0] - 2026-08-15

### 修复
- `local fn` 非法语法（MAXScript 无此组合）→ `fn`
- exportDoc 内嵌套函数引用外层局部（无闭包）→ 删除嵌套，改用顶层块级函数
- exportDoc 拆分三阶段：`buildInfos`（收集）/ `renderMD`（渲染）/ `writeMDFile`（写盘）+ 薄协调层，数据经参数/返回值传递
- `bit.char` 不存在 → `bit.intAsChar 13/10`；`trim` 不存在 → `trimLeft`/`trimRight`
- ArrayParameter 伪材质导致「No map function for undefined」→ `getPropNames` 结果防御

### 变更
- 面板二日志框高度 60 → 240px

## [3.0.0] - 2026-07-15

### 新增
- V-Ray 材质一键替换（Standard / Physical 双目标）
- 导出材质构成 MD（含 AI 提示词，可生成 HTML 报告）
- VRayBitmap / VRayHDRI → BitmapTexture 可选转换
- 多维子材质递归处理、`replaceInstances` 全局替换
- 「复制 AI 提示词」按钮

[3.2.0]: https://github.com/Simiely/vray-material-replacer/compare/v3.1.0...v3.2.0
[3.1.0]: https://github.com/Simiely/vray-material-replacer/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/Simiely/vray-material-replacer/releases/tag/v3.0.0
