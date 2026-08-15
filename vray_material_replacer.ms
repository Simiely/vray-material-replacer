-------------------------------------------------------------------------------
-- 材质工具箱 (Material Toolkit)  v3  [交叉验证版]
-- 验证来源：Autodesk 官方 MAXScript 帮助、Chaos(V-Ray) 官方文档与论坛、
--           3ds Max 官方编程论坛(Autodesk)、ScriptSpot、CGTalk、denisT.MaxDoctor 等。
--
-- 包含三大功能：
--   【面板一】材质一键替换（V-Ray → Standard / Physical；可勾选统一转换所有材质 + 转换前自动备份 .mat 可恢复）
--   【面板二】程序贴图烘焙（程序贴图 → 位图，FBX 导出兼容）
--   【面板三】导出场景所有材质的「构成」为 Markdown 文档（结构已为 AI→HTML 优化）
--
-- 关键修正（均已交叉验证）：
--   1) 遍历「对象材质 + 材质编辑器槽位 + 递归子材质」收集场景【全部】材质；getClassInstances 不接受抽象基类 Material。
--   2) replaceInstances 全局一次性替换所有引用，最稳定、不漏嵌套。
--   3) 标准材质“启用贴图”属性是 diffuseMapEnable（非 useDiffuseMap）。
--   4) VRayBitmap/VRayHDRI 文件名用 .HDRIMapName 读取。
--   5) 包裹类材质取 baseMtl / frontmtl 子材质转换，保留真实外观。
--   6) Physical 贴图槽名跨版本差异（base_color_map / base_color_map_map）两种都试。
--   7) 贴图槽位枚举用 getNumSubTexmaps + getSubTexmapSlotName（官方 API）。
--
-- 用法：MAXScript 编辑器打开本文件 -> Ctrl+E 运行 -> 弹窗操作。
-- 建议：操作前先保存场景（替换可 Ctrl+Z 撤销；导出只读、不改场景）。
-------------------------------------------------------------------------------

(
    -- ===================== 共享工具函数 =====================
    local canPhysical = (try(PhysicalMaterial != undefined) catch false)   -- 类存在性探测（不构造实例，更轻量）
    global gExpStage = ""

    fn pad2 s = ( if s.count < 2 then ("0" + s) else s )

    -- 颜色 → #RRGGBB。兼容 Color / AColor / Point3（MAXScript 三类颜色值）
    -- AColor 带 alpha（忽略）；Point3 分量常为 0-1 浮点，Color 为 0-255 整数
    fn colorToHex c = (
        try (
            local cr = c.r, cg = c.g, cb = c.b
            -- 0-1 浮点（Point3/AColor 常见）→ 转 0-255；0-255 整数原样
            if cr <= 1.0 and cg <= 1.0 and cb <= 1.0 and cr >= 0 and cg >= 0 and cb >= 0 then (
                cr = cr * 255.0 ; cg = cg * 255.0 ; cb = cb * 255.0
            )
            "#" + (pad2 (bit.intAsHex (cr as integer))) + (pad2 (bit.intAsHex (cg as integer))) + (pad2 (bit.intAsHex (cb as integer)))
        ) catch ( "#000000" )
    )

    -- 读取任意贴图的文件路径（BitmapTexture 用 .filename；VRayBitmap/VRayHDRI 用 .HDRIMapName）
    fn mapFilename tm = (
        if tm == undefined do return ""
        local fn2 = ""
        local clsT = try ((classof tm) as string) catch ""
        if (clsT == "VRayBitmap" or clsT == "VRayHDRI") then (
            try ( fn2 = tm.HDRIMapName ) catch ()
        ) else (
            try ( fn2 = tm.filename ) catch ()
        )
        if fn2 == undefined do fn2 = ""
        fn2
    )

    -- 当前时间字符串
    fn nowStr = (
        local t = getLocalTime()
        local y = t[1] as string
        local m = (if t[2] < 10 then "0" + (t[2] as string) else t[2] as string)
        local d = (if t[3] < 10 then "0" + (t[3] as string) else t[3] as string)
        local hh = (if t[4] < 10 then "0" + (t[4] as string) else t[4] as string)
        local mm = (if t[5] < 10 then "0" + (t[5] as string) else t[5] as string)
        (y + "-" + m + "-" + d + " " + hh + ":" + mm)
    )

    -- 文件安全时间戳（YYYYMMDD_HHMMSS，无冒号/空格，用于备份文件名——避免二次转换覆盖原备份）
    fn fileStamp = (
        local t = getLocalTime()
        ((t[1] as string) + (pad2 (t[2] as string)) + (pad2 (t[3] as string)) + "_" + (pad2 (t[4] as string)) + (pad2 (t[5] as string)) + (pad2 (t[6] as string)))
    )

    -- 场景基础目录（当前打开工程所在目录，含尾斜杠；未保存场景回退用户脚本目录）——每次实时计算，
    -- 供导出/烘焙/浏览的默认路径使用，切换工程后自动跟随新工程目录（不用重启脚本）
    fn sceneBaseDir = (
        if maxFileName != "" then maxFilePath
        else ((getDir #userScripts) + "\\")
    )
    -- 记录两个面板上次自动设置的默认路径：用户未手动修改时（仍等于该值），按钮点击会刷新为当前工程目录
    global gLastExportDefault = ""
    global gLastBakeDefault = ""

    -- 清理名称（去掉换行/回车/首尾空白，避免破坏 Markdown）
    fn cleanName s = (
        s = s as string
        s = substituteString s (bit.intAsChar 13) " "   -- CR（bit.intAsChar 返回整数对应字符；bit.char 不存在！）
        s = substituteString s (bit.intAsChar 10) " "   -- LF
        trimRight (trimLeft s)   -- MAXScript 无 trim，只有 trimLeft/trimRight（官方 String Parser Methods）
    )

    -- 用分隔符拼接字符串数组（MaxScript 无内置 sep-join）
    fn joinStr arr sep = (
        local s = ""
        for i = 1 to arr.count do (
            s += (arr[i] as string)
            if i < arr.count do s += sep
        )
        s
    )

    -- 递归收集材质：&acc 为按引用传递的数组；遍历多维子材质与常见包裹/混合/双面子材质
    fn recurseMats &acc m =
    (
        if m == undefined do return undefined
        if (findItem acc m) != 0 do return undefined   -- 已收集过（含防环），直接返回避免无限递归
        append acc m
        if (isProperty m #materialList) do
            for sm in m.materialList where sm != undefined do recurseMats &acc sm
        if (isProperty m #baseMtl)   and m.baseMtl   != undefined do recurseMats &acc m.baseMtl
        if (isProperty m #frontmtl)  and m.frontmtl  != undefined do recurseMats &acc m.frontmtl
        if (isProperty m #backmtl)   and m.backmtl   != undefined do recurseMats &acc m.backmtl
        if (isProperty m #coatMtl)   and m.coatMtl   != undefined do recurseMats &acc m.coatMtl
        if (isProperty m #coatMtl1)  and m.coatMtl1  != undefined do recurseMats &acc m.coatMtl1
        if (isProperty m #coatMtl2)  and m.coatMtl2  != undefined do recurseMats &acc m.coatMtl2
        if (isProperty m #blendMtl1) and m.blendMtl1 != undefined do recurseMats &acc m.blendMtl1
        if (isProperty m #blendMtl2) and m.blendMtl2 != undefined do recurseMats &acc m.blendMtl2
        if (isProperty m #shellMtl)  and m.shellMtl  != undefined do recurseMats &acc m.shellMtl
        undefined
    )

    -- 收集场景内全部材质（对象材质 + 材质编辑器槽位 + 递归子材质）
    -- 不使用 getClassInstances Material：Material 是抽象基类，getClassInstances 只接受具体 MAXClass
    fn collectAllMaterials =
    (
        local result = #()
        for o in objects do
            if o.material != undefined do recurseMats &result o.material
        for i = 1 to meditMaterials.count do
            if meditMaterials[i] != undefined do recurseMats &result meditMaterials[i]
        result
    )

    -- ===================== AI 转换提示词（导出时写入 MD 开头） =====================
    -- 这份提示词会作为 HTML 注释写在导出 MD 的最前面，AI 读取 MD 时会一并看到。
    -- 改这里即可调整“MD -> HTML 报告”的渲染要求，无需动其它代码。
    global aiPromptLines = #(
        "你是一位资深前端工程师。下面是一份从 3ds Max 导出的「场景材质构成报告」Markdown 文档。",
        "请把它转换成【单文件、可离线打开、完全自包含】的 HTML 可视化报告：HTML + CSS + JS 全部内联，不依赖任何外部库或网络请求。",
        "",
        "【页面要求】",
        "1. 顶部放置统计卡片：材质总数、V-Ray 材质数、使用材质对象数。",
        "2. 提供目录（TOC），利用文档中的锚点 #mat-1、#mat-2 … 实现点击跳转到对应材质卡片。",
        "3. 每个材质渲染为一张卡片，包含：",
        "   - 材质名称与类型标签（VRayMtl / Standard / Physical / MultiMaterial 等；V-Ray 类加醒目标记）；",
        "   - 「使用对象」列表（若有）；",
        "   - 「颜色参数」：把 #RRGGBB 渲染成真实色块 + 十六进制文字；",
        "   - 「数值参数」：用表格展示；",
        "   - 「贴图」：用表格展示槽位 / 类型 / 文件 / 启用；文件路径若以盘符或 http 开头，渲染为可点击链接；",
        "   - 「子材质」：渲染为可点击锚点链接，跳转到对应材质卡片。",
        "4. 支持「浅色 / 深色 / 跟随系统」三档主题切换，切换有平滑过渡；默认跟随系统。",
        "5. 现代卡片 + 表格风格，留白充足、排版精致；移动端响应式；交互动画流畅（60fps）。",
        "6. 纯静态，双击即可在浏览器打开，不要写任何需要服务器的代码。",
        "",
        "请直接输出完整 HTML 代码，不要省略、不要只给片段。"
    )
    global aiPrompt = joinStr aiPromptLines "\n"

    -- 取得场景里“使用某材质的对象名”映射（在导出时调用，保证最新）
    -- 注意：避免 for...where... 嵌套过滤（内层 where 引用外层循环变量是 MAXScript 作用域解析边界情况，
    -- 曾有「调用需要函数或类，得到的是 undefined」报错），统一用朴素的 for + if 写法。
    fn buildMatObjectMap = (
        local map = #()  -- 元素为 #(material, #(objName,...))
        for o in objects do
        (
            if o.material != undefined do
            (
                local found = false
                for pair in map do
                (
                    if pair[1] == o.material do
                    (
                        append pair[2] (cleanName o.name)
                        found = true
                    )
                )
                if not found do append map #(o.material, #(cleanName o.name))
            )
        )
        map
    )

    fn getMatObjects mtlObjMap m = (
        for pair in mtlObjMap do
            if pair[1] == m do return pair[2]
        #()
    )

    -- ===================== 材质备份 / 恢复（可逆转换） =====================
    -- 依据：官方 MAXScript 文档 saveTempMaterialLibrary（BOBO 论坛验证：sceneMaterials 是 MaterialLibrary，
    --       可直接保存为 .mat 且不污染当前材质库）+ 官方 SceneConverter 核心接口
    --       OverwriteFromMaterialLibrary（场景转换器自带的"保存/还原材质版本"机制，按同名材质覆盖回场景）。
    -- 备份路径记入 global gBackupPath，供恢复按钮使用。
    global gBackupPath = ""

    -- 保存场景材质为 .mat 备份文件（返回 true/false）
    fn backupSceneMats path = (
        local ok = false
        try ( ok = (saveTempMaterialLibrary sceneMaterials path) ) catch ( ok = false )
        ok
    )

    -- 从 .mat 备份恢复场景材质（同名覆盖；SceneConverter 2017+ 官方核心接口，直接点号调用，无需实例化）
    fn restoreSceneMats path = (
        local ok = false
        try ( SceneConverter.OverwriteFromMaterialLibrary path; ok = true ) catch ( ok = false )
        ok
    )

    -- ===================== 程序贴图烘焙（FBX 导出兼容） =====================
    -- 目的：把 3ds Max 程序贴图（ColorCorrect / Gradient / Noise 等非 BitmapTexture）
    --       烘焙成位图文件，并替换回材质，使 FBX 导出后其他软件能正确显示贴图。
    -- 依据：Autodesk 官方 renderMap 方法 + 官方知识库「Procedural texture → bitmap for .fbx export」。

    -- 收集材质里的所有「非 BitmapTexture」贴图（递归子贴图；返回 #(map, slotName, ownerMtl, ownerSlotIdx)）
    fn collectProcMaps mats = (
        local result = #()   -- 元素为 #(tm, ownerMtl, slotIdx)
        local seen = #()     -- 防环/去重：同一个贴图实例只收集一次
        for m in mats do
        (
            -- 递归该材质的所有贴图槽
            local stack = #(m)  -- 用显式栈模拟递归（MAXScript 递归也可，但避免嵌套 fn）
            while stack.count > 0 do
            (
                local cur = stack[stack.count]
                deleteItem stack stack.count
                local nTex = (try(getNumSubTexmaps cur)catch(0))
                for k = 1 to nTex do
                (
                    local tm = (try(getSubTexmap cur k)catch(undefined))
                    if tm != undefined do
                    (
                        -- 收集非 BitmapTexture 的程序贴图（且未收集过）
                        if (classof tm != BitmapTexture) and (findItem seen tm) == 0 do
                        (
                            append seen tm
                            append result #(tm, cur, k)
                        )
                        -- 程序贴图内部可能还有子贴图（如 Mix 的两个颜色源），继续入栈
                        -- 防环（P-01）：已收集过的贴图不再入栈，避免循环引用贴图树（A 含 A）无限循环卡死
                        if (classof tm != BitmapTexture) and (findItem seen tm) == 0 do append stack tm
                    )
                )
            )
        )
        result
    )

    -- 烘焙单个贴图到文件，返回输出文件路径（失败返回 undefined）
    fn bakeMapToFile tm outDir sizeVal =
    (
        if tm == undefined do return undefined
        local safeName = cleanName (try(tm.name)catch("map"))
        if safeName == "" do safeName = "map"
        -- 文件名：分+秒+随机数 后缀，避免同贴图多槽位/同名不同实例烘焙互相覆盖（P-03）
        local ts = getLocalTime()
        local stamp = ((ts[5] as string) + (ts[6] as string) + "_" + ((random 100 999) as string))
        local outFile = (outDir + "\\baked_" + safeName + "_" + stamp + ".png")
        try (
            local bm = renderMap tm size:[sizeVal, sizeVal] fileName:outFile
            if bm != undefined do ( save bm; close bm )
            outFile
        ) catch ( undefined )
    )

    -- 烘焙单个贴图并替换槽位（返回成功与否）
    fn bakeAndReplace tm ownerMtl slotIdx outDir sizeVal =
    (
        if tm == undefined do return false
        local outFile = bakeMapToFile tm outDir sizeVal
        if outFile == undefined do return false
        local ok = false
        try (
            local nb = BitmapTexture()
            try ( nb.filename = outFile ) catch ()
            try ( nb.name = ((try(tm.name)catch("map")) as string + "_baked") ) catch ()
            setSubTexmap ownerMtl slotIdx nb
            ok = true
        ) catch ( ok = false )
        ok
    )

    -- 烘焙单个贴图但不替换（纯输出文件，返回成功与否）
    fn bakeOnly tm outDir sizeVal =
    (
        (bakeMapToFile tm outDir sizeVal) != undefined
    )

    -- 材质信息结构体（仅定义一次，避免重复定义报错）
    struct MatInfo (idx, mat, dispName, className, isVRay, objNames, subIdx, maps, colors, nums)

    -- ===================== 导出：三阶段拆分（收集 / 渲染 / 写盘） =====================
    -- 拆分原则：MAXScript 无闭包，跨函数共享数据一律通过返回值 / 参数传递，
    -- 每个 fn 只干一件事，避免大函数内主支线混编、难调试（历史 bug 多源于此）。

    -- 阶段 1：收集材质信息（支线：数据准备）。返回 infos 数组（MatInfo 元素）。
    fn buildInfos includeObjs includeMaps includeParams = (
        global gExpStage
        gExpStage = "collect"
        local mats = collectAllMaterials()
        local objMap = #()
        if includeObjs do (
            gExpStage = "objmap"
            -- 防御：函数缺失时明确报错而非对 undefined 调用（历史 bug 定位手段，保留一行兜底）
            if buildMatObjectMap == undefined do throw "buildMatObjectMap 未定义"
            objMap = buildMatObjectMap()
        )
        local infos = #()
        for i = 1 to mats.count do
        (
            gExpStage = ("infos#" + (i as string))
            local m = mats[i]
            local cls = (classof m) as string
            local isV = matchPattern cls pattern:"VRay*"
            local dName = cleanName (try(m.name)catch(cls))
            if dName == "" or dName == undefined do dName = cls
            local subIdx = #()
            local nSub = (try(getNumSubMtls m)catch(0))
            for k = 1 to nSub do (
                local sm = (try(getSubMtl m k)catch(undefined))
                if sm != undefined do (
                    local idx = findItem mats sm
                    if idx > 0 do append subIdx idx
                )
            )
            local maps = #()
            if includeMaps do (
                local nTex = (try(getNumSubTexmaps m)catch(0))
                for k = 1 to nTex do (
                    local tm = (try(getSubTexmap m k)catch(undefined))
                    if tm != undefined do (
                        local slot = (try(getSubTexmapSlotName m k)catch("slot " + (k as string)))
                        local clsM = (classof tm) as string
                        local fnm = mapFilename tm
                        -- 贴图启用状态（P-02）：BitmapTexture 无 enabled 属性（官方属性表确认，读它必 false）。
                        -- 改为反查材质属性：找到引用本贴图的槽位属性（如 diffuseMap / base_color_map），
                        -- 再读其启用开关（Standard: <slot>MapEnable；Physical: <slot>_map_enabled）。
                        -- 读取失败按 true（已连接即视为启用）处理，避免报告「启用」列全"否"误导。
                        local en = true
                        try (
                            local mProps = getPropNames m
                            local mapProp = undefined
                            for p in mProps do (
                                if (try((getProperty m p) == tm)catch(false)) do ( mapProp = p; exit )
                            )
                            if mapProp != undefined do (
                                local pn = (mapProp as string)
                                if (hasProperty m (pn + "Enable"))   do ( en = ((getProperty m (pn + "Enable")) == true) )
                                if (hasProperty m (pn + "_enabled")) do ( en = ((getProperty m (pn + "_enabled")) == true) )
                            )
                        ) catch ( en = true )
                        append maps #(slot, clsM, fnm, en)
                    )
                )
            )
            local colors = #()
            local nums = #()
            if includeParams do (
                -- 防御：getPropNames 对非材质对象（如 ArrayParameter）可能返回 undefined，
                -- for 循环遍历 undefined 会报「没有与以下项对应的 map 函数」（No "map" function for undefined）
                local props = (try(getPropNames m)catch(#()))
                if props == undefined do props = #()
                for p in props do
                (
                    local pname = (p as string)
                    if (matchPattern pname pattern:"*map*") or pname == "name" do continue
                    local val
                    try ( val = getProperty m p ) catch ( continue )
                    if val == undefined do continue
                    -- 颜色值兼容三类（Color / AColor / Point3）：Color 与 AColor 是 isKindOf Color 的兄弟类，
                    -- 官方文档：AColor 是 Color 的子类，Point3 语义上是 [r,g,b] 也可当颜色。用 isKindOf 兜底。
                    if (isKindOf val Color) or (classof val == Point3) then (
                        append colors #(pname, (colorToHex val))
                    ) else if (isKindOf val Number) then (
                        append nums #(pname, (val as string))
                    )
                )
            )
            local objs = #()
            if includeObjs do objs = getMatObjects objMap m
            append infos (MatInfo i m dName cls isV objs subIdx maps colors nums)
        )
        gExpStage = "infos_done"
        infos
    )

    -- 阶段 2：渲染 Markdown（主线：文档生成）。返回整篇 MD 字符串。
    fn renderMD infos includeObjs includeMaps = (
        global gExpStage
        gExpStage = "writeMD"
        local nTotal = infos.count
        local nVRay = 0
        for inf in infos do ( if inf.isVRay do nVRay += 1 )
        local objCount = 0
        for o in objects do ( if o.material != undefined do objCount += 1 )

        local ss = ""
        ss += "<!--" + "\n"
        ss += "【AI 转换提示】下面这段文字是给 AI 的指令，用来把本文档转换成 HTML 可视化报告；本段可整段删除，不影响报告数据。" + "\n"
        for line in aiPromptLines do ss += line + "\n"
        ss += "-->" + "\n"
        ss += "" + "\n"
        ss += "# 3ds Max 场景材质构成报告" + "\n"
        ss += "" + "\n"
        ss += "| 项目 | 值 |" + "\n"
        ss += "|------|----|" + "\n"
        ss += ( "| 生成时间 | " + (nowStr()) + " |" ) + "\n"
        ss += ( "| 场景文件 | " + (if maxFileName != "" then (maxFilePath + maxFileName) else "（未保存的场景）") + " |" ) + "\n"
        ss += ( "| 3ds Max 版本 | " + ((maxVersion())[1] as string) + " |" ) + "\n"
        ss += ( "| 材质总数 | " + (nTotal as string) + " |" ) + "\n"
        ss += ( "| 使用材质对象数 | " + (objCount as string) + " |" ) + "\n"
        ss += ( "| V-Ray 材质数 | " + (nVRay as string) + " |" ) + "\n"
        ss += "" + "\n"
        ss += "## 目录" + "\n"
        ss += "" + "\n"
        ss += "- [材质总览](#mat-overview)" + "\n"
        ss += "- [材质详情](#mat-details)" + "\n"
        for inf in infos do
        (
            ss += ( "  - [" + (inf.idx as string) + ". " + inf.dispName + " (" + inf.className + ")](#mat-" + (inf.idx as string) + ")" ) + "\n"
        )
        ss += "" + "\n"
        ss += "<a id=\"mat-overview\"></a>" + "\n"
        ss += "## 材质总览" + "\n"
        ss += "" + "\n"
        ss += "| # | 名称 | 类型 | 使用对象数 | 子材质数 | 贴图数 | V-Ray |" + "\n"
        ss += "|---|------|------|-----------|---------|--------|-------|" + "\n"
        for inf in infos do
        (
            local objN = if includeObjs then (inf.objNames.count as string) else "—"
            local subN = (inf.subIdx.count as string)
            local mapN = (inf.maps.count as string)
            local vTag = if inf.isVRay then "是" else "否"
            ss += ( "| " + (inf.idx as string) + " | " + inf.dispName + " | " + inf.className + " | " + objN + " | " + subN + " | " + mapN + " | " + vTag + " |" ) + "\n"
        )
        ss += "" + "\n"
        ss += "<a id=\"mat-details\"></a>" + "\n"
        ss += "## 材质详情" + "\n"
        ss += "" + "\n"
        for inf in infos do
        (
            ss += ( "<a id=\"mat-" + (inf.idx as string) + "\"></a>" ) + "\n"
            ss += ( "### " + (inf.idx as string) + ". " + inf.dispName ) + "\n"
            ss += ( "- **类型**：" + inf.className + (if inf.isVRay then "  （V-Ray）" else "") ) + "\n"
            if includeObjs do (
                if inf.objNames.count > 0 then (
                    ss += ( "- **使用对象** (" + (inf.objNames.count as string) + ")：" + (joinStr inf.objNames ", ") ) + "\n"
                ) else (
                    ss += "- **使用对象**：（无 / 仅存在于材质编辑器或子材质中）" + "\n"
                )
            )
            if inf.colors.count > 0 do (
                ss += "- **颜色参数**" + "\n"
                ss += "" + "\n"
                ss += "  | 属性 | 值 |" + "\n"
                ss += "  |------|----|" + "\n"
                for c in inf.colors do (
                    if c != undefined and c.count >= 2 do (
                        ss += ( "  | " + (c[1] as string) + " | " + (c[2] as string) + " |" ) + "\n"
                    )
                )
                ss += "" + "\n"
            )
            if inf.nums.count > 0 do (
                ss += "- **数值参数**" + "\n"
                ss += "" + "\n"
                ss += "  | 属性 | 值 |" + "\n"
                ss += "  |------|----|" + "\n"
                for n in inf.nums do (
                    if n != undefined and n.count >= 2 do (
                        ss += ( "  | " + (n[1] as string) + " | " + (n[2] as string) + " |" ) + "\n"
                    )
                )
                ss += "" + "\n"
            )
            if includeMaps and inf.maps.count > 0 do (
                ss += ( "- **贴图** (" + (inf.maps.count as string) + ")" ) + "\n"
                ss += "" + "\n"
                ss += "  | 槽位 | 类型 | 文件 | 启用 |" + "\n"
                ss += "  |------|------|------|------|" + "\n"
                for mp in inf.maps do
                (
                    if mp != undefined and mp.count >= 4 do (
                        local fnm = if (mp[3] as string) == "" then "—" else (mp[3] as string)
                        local en = if mp[4] then "是" else "否"
                        ss += ( "  | " + (mp[1] as string) + " | " + (mp[2] as string) + " | " + fnm + " | " + en + " |" ) + "\n"
                    )
                )
                ss += "" + "\n"
            )
            if inf.subIdx.count > 0 do (
                local links = ""
                for si in inf.subIdx do ( links += "[#" + (si as string) + " " + (infos[si].dispName as string) + "](#mat-" + (si as string) + ")、" )
                if links.count > 0 do links = substring links 1 (links.count - 1)
                ss += ( "- **子材质** (" + (inf.subIdx.count as string) + ")：" + links ) + "\n"
            )
            ss += "" + "\n"
            ss += "---" + "\n"
            ss += "" + "\n"
        )
        gExpStage = "writeMD_done"
        ss
    )

    -- 阶段 3：写盘（基础设施）。返回成功与否。
    fn writeMDFile path content = (
        global gExpStage
        gExpStage = "writeFile"
        local f = createFile path
        format "%" content to:f
        close f
        gExpStage = "done"
        true
    )

    -- 协调层（主线入口：三阶段串联，只传数据不写逻辑）
    fn exportDoc path includeObjs includeMaps includeParams = (
        global gExpStage
        gExpStage = "init"
        local infos = buildInfos includeObjs includeMaps includeParams
        local md    = renderMD infos includeObjs includeMaps
        writeMDFile path md
    )

    -- ===================== 面板一：V-Ray 材质替换 =====================
    -- 预声明后续 rollouts：面板一 btnRefresh 事件要跨面板访问 rlBake/rlExport，
    -- MAXScript 要求被引用名字先声明（否则事件处理器内被隐式声明为局部 undefined → 「未知属性 edtDir 位于 undefined」）
    local rlBake, rlExport
    rollout rlVRayReplace "① V-Ray 材质替换" width:340 height:560
    (
        -- 目标材质类型：单选按钮（1=Standard，2=Physical；与旧 dropdownList 的 selection 语义一致）
        radiobuttons rdoTarget "目标材质类型:" labels:#("Standard (标准材质)", "Physical (物理材质)") default:1 columns:1
        checkbox     chkMaps   "保留漫反射/凹凸/透明贴图" checked:true
        checkbox     chkBitmap "把 VRayBitmap / VRayHDRI 转为 Bitmap" checked:false
        checkbox     chkAll    "统一转换所有材质（含 Standard/Physical 互转）" checked:false
        button       btnGo     "开始替换 V-Ray 材质" width:310 height:36
        button       btnCount  "仅统计 V-Ray 材质（不替换）" width:310 height:24
        checkbox     chkBackup "转换前自动备份原材质（.mat，可一键恢复）" checked:true
        button       btnRestore "从备份恢复原材质（撤销转换）" width:310 height:24
        button       btnRefresh "一键刷新所有路径为当前工程目录" width:310 height:24
        edittext     edtLog    "" width:310 height:188 readOnly:true

        -- 按钮文案联动（P-05）：勾选「统一转换」时按钮/统计按钮文案相应变化
        on chkAll changed v do (
            btnGo.text = if v then "开始统一转换所有材质" else "开始替换 V-Ray 材质"
            btnCount.text = if v then "统计全部材质（不转换）" else "仅统计 V-Ray 材质（不替换）"
        )

        -- 一键刷新：把面板二（烘焙目录）+ 面板三（导出路径）都重置为当前打开的工程目录。
        -- 用途：启动 Max 时插件先弹窗（场景未加载），open 事件拿到的默认路径是旧值；
        --       打开/切换工程后点此按钮立即同步所有地址（事件在点击时执行，此时 rlBake/rlExport 均已定义，可跨面板访问）。
        on btnRefresh pressed do (
            gLastBakeDefault = (sceneBaseDir() + "_baked_maps")
            rlBake.edtDir.text = gLastBakeDefault
            gLastExportDefault = (sceneBaseDir() + "材质构成报告.md")
            rlExport.edtPath.text = gLastExportDefault
            edtLog.text = ("已刷新所有路径为当前工程目录：\n\n" + (if maxFileName != "" then (maxFilePath + maxFileName) else "（未保存场景，回退用户脚本目录）") + "\n\n烘焙目录：\n" + gLastBakeDefault + "\n\n导出路径：\n" + gLastExportDefault)
        )

        fn convBitmap m =
        (
            local clsM = try ((classof m) as string) catch ""
            if (clsM == "VRayBitmap" or clsM == "VRayHDRI") then
            (
                local nb = BitmapTexture()
                try ( nb.filename = m.HDRIMapName ) catch ()
                try ( nb.name = m.name ) catch ()
                nb
            )
            else m
        )

        fn setPhysMap pmtl baseName val =
        (
            try ( setProperty pmtl (baseName + "_map") val; setProperty pmtl (baseName + "_map_enabled") true ) catch (
                try ( setProperty pmtl (baseName + "_map_map") val; setProperty pmtl (baseName + "_map_map_enabled") true ) catch ()
            )
        )

        -- 转换函数族统一加 keepMaps 参数（替代直接读 chkMaps.checked），与 UI 解耦
        fn vrMtlToStandard src keepMaps:true = (
            local r = StandardMaterial()
            r.name = src.name
            try ( r.diffuse = src.diffuse ) catch ()
            -- 数值参数迁移（Standard 能力有限，仅能迁移 glossiness/ior/自发光；metalness 无对应属性）
            -- Standard 的 glossiness：100 = 无高光（模糊），与 VRay 光泽度互补
            try ( if (hasProperty src "reflection_glossiness") do r.glossiness = (100.0 - (src.reflection_glossiness * 100.0)) ) catch ()
            try ( if (hasProperty src "reflection_ior") do r.ior = src.reflection_ior ) catch ()
            -- 自发光：VRay selfIllumination 颜色 → Standard 自发光
            try ( if (hasProperty src "selfIllumination") and src.selfIllumination != (color 0 0 0) do ( r.useSelfIllumColor = true; r.selfIllumColor = src.selfIllumination; r.selfIllumAmount = 100 ) ) catch ()
            -- 透明度：VRay refraction 权重 > 0 时 Standard opacity 相应降低
            try ( if (hasProperty src "refraction") and src.refraction > 0 do r.opacity = (100.0 - (src.refraction * 100.0)) ) catch ()
            if keepMaps do (
                try ( if (src.texmap_diffuse != undefined and (try (src.texmap_diffuse_on == true) catch true)) do ( r.diffuseMap = convBitmap src.texmap_diffuse; r.diffuseMapEnable = true ) ) catch ()
                try ( if (src.texmap_bump != undefined and (try (src.texmap_bump_on == true) catch true)) do ( r.bumpMap = convBitmap src.texmap_bump; r.bumpMapEnable = true ) ) catch ()
                try ( if (src.texmap_opacity != undefined and (try (src.texmap_opacity_on == true) catch true)) do ( r.opacityMap = convBitmap src.texmap_opacity; r.opacityMapEnable = true ) ) catch ()
            )
            r
        )

        fn vrMtlToPhysical src keepMaps:true = (
            local r = PhysicalMaterial()
            r.name = src.name
            -- 颜色：漫反射
            try ( if (hasProperty src "diffuse") do r.base_color = src.diffuse ) catch ()
            try ( if (hasProperty src "color")   do r.base_color = src.color   ) catch ()
            -- 数值参数迁移（映射依据：Chaos 官方文档 VRayMtl 属性表 + Physical 实测脚本，全部 hasProperty 防御）
            -- 金属度：直传（VRay reflection_metalness → Physical metalness）
            try ( if (hasProperty src "reflection_metalness") do r.metalness = src.reflection_metalness ) catch ()
            -- 粗糙度：Physical 的 roughness 与 VRay 光泽度互补（1 - glossiness）
            try ( if (hasProperty src "reflection_glossiness") do r.roughness = (1.0 - src.reflection_glossiness) ) catch ()
            -- IOR：反射 IOR（无折射材质用反射 IOR）
            try ( if (hasProperty src "reflection_ior") do r.ior = src.reflection_ior ) catch ()
            -- 折射 IOR 覆盖（有折射时更准确）
            try ( if (hasProperty src "refraction_ior") and src.refraction_ior != undefined do r.ior = src.refraction_ior ) catch ()
            -- 反射颜色 → reflect_color
            try ( if (hasProperty src "reflection") do r.reflect_color = src.reflection ) catch ()
            -- 折射：transparency 权重 + 透射色
            try ( if (hasProperty src "refraction") do r.transparency = src.refraction ) catch ()
            try ( if (hasProperty src "refraction_fogColor") do r.trans_color = src.refraction_fogColor ) catch ()
            -- 自发光：颜色 + 强度
            try ( if (hasProperty src "selfIllumination") do r.emission_color = src.selfIllumination ) catch ()
            try ( if (hasProperty src "selfIllumination_multiplier") do r.emission_level = src.selfIllumination_multiplier ) catch ()
            -- 漫反射粗糙度
            try ( if (hasProperty src "diffuse_roughness") do r.diff_roughness = src.diffuse_roughness ) catch ()
            -- 补充颜色迁移（Chaos 官方 VRayMtl 颜色属性表：translucency/coat/sheen；Physical 有对应属性）
            -- 半透明色（SSS）：VRay translucency_color → Physical translucency_color
            try ( if (hasProperty src "translucency_color") do r.translucency_color = src.translucency_color ) catch ()
            -- 涂层色：VRay coat_color → Physical coat_color
            try ( if (hasProperty src "coat_color") do r.coat_color = src.coat_color ) catch ()
            -- 反射的 IOR 在反射/折射中已覆盖；折射雾色已迁移为 trans_color
            -- 贴图（原有逻辑）
            if keepMaps do (
                try ( if (hasProperty src "texmap_diffuse") and src.texmap_diffuse != undefined do ( setPhysMap r "base_color" (convBitmap src.texmap_diffuse) ) ) catch ()
                try ( if (hasProperty src "texmap_reflection") and src.texmap_reflection != undefined do ( setPhysMap r "reflect_color" (convBitmap src.texmap_reflection) ) ) catch ()
                -- 凹凸贴图：VRay texmap_bump → Physical bump_map（Max 官方博客：physMtl.bump_map = normalBump 用法）
                try ( if (hasProperty src "texmap_bump") and src.texmap_bump != undefined do ( setPhysMap r "bump" (convBitmap src.texmap_bump) ) ) catch ()
            )
            r
        )

        -- ===== 全场景统一：Standard ↔ Physical 双向转换 =====
        -- 映射依据（官方转换脚本通用做法 + MAXScript 属性表）：
        --   Standard: diffuse / glossiness(0-100) / specular_level / selfIllumColor / useSelfIllumColor / opacity(0-100) / ior / diffuseMap / bumpMap
        --   Physical: base_color / roughness(0-1) / emission_color / emission_level / transparency(0-1) / ior / base_color_map / bump_map
        --   转换规则：glossiness→roughness = 1-g/100；opacity→transparency = (100-opacity)/100；反向同理。
        fn stdToPhysical src keepMaps:true = (
            local r = PhysicalMaterial()
            r.name = src.name
            try ( if (hasProperty src "diffuse") do r.base_color = src.diffuse ) catch ()
            try ( if (hasProperty src "glossiness") do r.roughness = (1.0 - (src.glossiness / 100.0)) ) catch ()
            try ( if (hasProperty src "ior") do r.ior = src.ior ) catch ()
            try ( if (hasProperty src "opacity") do r.transparency = ((100.0 - src.opacity) / 100.0) ) catch ()
            try ( if (hasProperty src "selfIllumColor") and src.useSelfIllumColor do ( r.emission_color = src.selfIllumColor; r.emission_level = (try(src.selfIllumAmount)catch(0)) / 100.0 ) ) catch ()
            if keepMaps do (
                try ( if src.diffuseMap != undefined and src.diffuseMapEnable do ( setPhysMap r "base_color" (convBitmap src.diffuseMap) ) ) catch ()
                try ( if src.bumpMap != undefined and src.bumpMapEnable do ( setPhysMap r "bump" (convBitmap src.bumpMap) ) ) catch ()
            )
            r
        )

        fn physToStandard src keepMaps:true = (
            local r = StandardMaterial()
            r.name = src.name
            try ( if (hasProperty src "base_color") do r.diffuse = src.base_color ) catch ()
            try ( if (hasProperty src "roughness") do r.glossiness = ((1.0 - src.roughness) * 100.0) ) catch ()
            try ( if (hasProperty src "ior") do r.ior = src.ior ) catch ()
            try ( if (hasProperty src "transparency") do r.opacity = ((1.0 - src.transparency) * 100.0) ) catch ()
            try ( if (hasProperty src "emission_color") and src.emission_color != (color 0 0 0) do ( r.useSelfIllumColor = true; r.selfIllumColor = src.emission_color; r.selfIllumAmount = (try(src.emission_level)catch(0)) * 100.0 ) ) catch ()
            if keepMaps do (
                try ( if src.base_color_map != undefined do ( r.diffuseMap = convBitmap src.base_color_map; r.diffuseMapEnable = true ) ) catch ()
                try ( if src.bump_map != undefined do ( r.bumpMap = convBitmap src.bump_map; r.bumpMapEnable = true ) ) catch ()
            )
            r
        )

        fn vrLightToStandard src keepMaps:true = (
            local r = StandardMaterial()
            r.name = src.name
            -- VRayLightMtl 无 diffuse 属性（Chaos 官方：参数只有 Color/Multiplier/Opacity/Texture）。
            -- 灯光颜色 color 同时迁移为「漫反射色」(diffuse) + 「自发光色」(selfIllumColor)：
            -- 否则转出的 Standard 漫反射是默认灰 #959595，灯光色值丢失。
            try ( if (hasProperty src "color")   do (
                r.useSelfIllumColor = true; r.selfIllumColor = src.color; r.selfIllumAmount = 100
                r.diffuse = src.color
            ) ) catch ()
            try ( if (hasProperty src "diffuse") do r.diffuse = src.diffuse ) catch ()
            if keepMaps do (
                -- texmap = 灯光颜色贴图（Chaos 官方：Texture 槽指定自发光颜色贴图）。
                -- 转换后同时接到「颜色贴图」(diffuseMap) 和「自发光贴图」(selfIllumMap)：
                -- diffuse 槽保证任意渲染器（扫描线/物理）下纹理可见，selfIllum 槽保留发光效果。
                -- 注意先转一次 bm 再复用，避免对同一 VRayBitmap 生成两个实例。
                try ( if (hasProperty src "texmap") and src.texmap != undefined do (
                    local bm = convBitmap src.texmap
                    r.diffuseMap = bm; r.diffuseMapEnable = true
                    r.selfIllumMap = bm; r.selfIllumMapEnable = true
                ) ) catch ()
                try ( if (hasProperty src "texmap_opacity") and src.texmap_opacity != undefined do ( r.opacityMap = convBitmap src.texmap_opacity; r.opacityMapEnable = true ) ) catch ()
            )
            r
        )

        fn vrGenericToStandard src keepMaps:true = (
            local r = StandardMaterial()
            r.name = src.name
            try ( if (hasProperty src "diffuse") do r.diffuse = src.diffuse ) catch ()
            try ( if (hasProperty src "color")   do ( r.useSelfIllumColor = true; r.selfIllumColor = src.color; r.selfIllumAmount = 100 ) ) catch ()
            if keepMaps do try ( if (hasProperty src "texmap_diffuse") and src.texmap_diffuse != undefined do ( r.diffuseMap = convBitmap src.texmap_diffuse; r.diffuseMapEnable = true ) ) catch ()
            r
        )

        -- 转换分发核心（与 UI 解耦：UI 状态由 allMode / keepMaps / canPhys 参数传入，不再读控件）
        fn convertMaterial src depth:1 canPhys:false allMode:false keepMaps:true =
        (
            if src == undefined do return undefined
            if depth > 12 do return (StandardMaterial())
            -- 非 V-Ray 材质：仅在「统一转换所有材质」模式下处理 Standard ↔ Physical 互转；
            -- 已是目标类型则原样返回（避免无意义重建）。多维子材质等其它类型保持原样。
            if not (matchPattern (classof src as string) pattern:"VRay*") do
            (
                local rv = src
                if allMode do
                (
                    rv = case classof src of
                    (
                        StandardMaterial: ( if canPhys then (stdToPhysical src keepMaps:keepMaps) else src )
                        PhysicalMaterial:  ( if canPhys then src else (physToStandard src keepMaps:keepMaps) )
                        default: src
                    )
                )
                return rv
            )

            case classof src of
            (
                VRayMtl:         ( if canPhys then (vrMtlToPhysical src keepMaps:keepMaps) else (vrMtlToStandard src keepMaps:keepMaps) )
                VRayLightMtl:    ( vrLightToStandard src keepMaps:keepMaps )
                VRayMtlWrapper:  ( convertMaterial src.baseMtl  depth:(depth+1) canPhys:canPhys allMode:allMode keepMaps:keepMaps )
                VRayBlendMtl:    ( convertMaterial src.baseMtl  depth:(depth+1) canPhys:canPhys allMode:allMode keepMaps:keepMaps )
                VRay2SidedMtl:   ( local fm = convertMaterial src.frontmtl depth:(depth+1) canPhys:canPhys allMode:allMode keepMaps:keepMaps; try ( fm.twoSided = true ) catch (); try ( fm.two_sided = true ) catch (); fm )
                VRayOverrideMtl: ( convertMaterial src.baseMtl  depth:(depth+1) canPhys:canPhys allMode:allMode keepMaps:keepMaps )
                VRayFastSSS2:    ( vrGenericToStandard src keepMaps:keepMaps )
                default:         ( vrGenericToStandard src keepMaps:keepMaps )
            )
        )

        on btnGo pressed do
        (
            -- P-14：防连点锁——处理中禁用按钮，异常也恢复（避免快速双击触发两次转换/两次备份）
            if not btnGo.enabled do return false
            btnGo.enabled = false
            try
            (
                local tgt = if (rdoTarget.state == 2 and canPhysical) then #physical else #standard
                local allMats  = collectAllMaterials()
                -- 收集待转换材质：勾选「统一转换所有材质」→ 全部；否则仅 VRay*
                local mats
                if chkAll.checked then
                    mats = for m in allMats where (matchPattern (classof m as string) pattern:"VRay*" or classof m == StandardMaterial or classof m == PhysicalMaterial) collect m
                else
                    mats = for m in allMats where matchPattern (classof m as string) pattern:"VRay*" collect m
                local nMat = mats.count
                local backupInfo = ""
                local failCount = 0   -- P-06：统计替换失败的材质数（不静默吞错）

                -- 转换前备份：把场景材质库存成 .mat（官方 saveTempMaterialLibrary，不污染当前材质库）
                if chkBackup.checked and nMat > 0 do
                (
                    local backupPath = (
                        -- P-13：文件名加时间戳，二次转换不覆盖含原始 VRay 材质的旧备份
                        if maxFileName != "" then (maxFilePath + (getFilenameFile maxFileName) + "_材质备份_" + (fileStamp()) + ".mat")
                        else ((getDir #userScripts) + "\\材质备份_" + (fileStamp()) + ".mat")
                    )
                    if (backupSceneMats backupPath) then
                    (
                        gBackupPath = backupPath
                        backupInfo = "\n\n已自动备份原材质：\n" + backupPath + "\n（如不满意可点「从备份恢复原材质」一键还原）"
                    )
                    else backupInfo = "\n\n（自动备份失败，请先保存场景再试）"
                )

                undo "Replace V-Ray Materials" on
                (
                    for m in mats do
                    (
                        local nm = convertMaterial m canPhys:(rdoTarget.state == 2 and canPhysical) allMode:chkAll.checked keepMaps:chkMaps.checked
                        if nm == undefined then ( failCount += 1 )
                        else try ( replaceInstances m nm ) catch ( failCount += 1 )
                    )

                    if chkBitmap.checked do
                    (
                        try ( for b in (getClassInstances VRayBitmap) do replaceInstances b (convBitmap b) ) catch ()
                        try ( for h in (getClassInstances VRayHDRI)  do replaceInstances h (convBitmap h) ) catch ()
                    )
                )

                edtLog.text = ( "完成。\n\n" + (if chkAll.checked then "已统一转换场景内全部材质：" else "发现 V-Ray 材质：") + nMat as string + " 个\n目标类型：" + (if tgt == #physical then "Physical" else "Standard") + "。\n" + (if failCount > 0 then "⚠ 失败 " + (failCount as string) + " 个（已跳过，见日志）\n" else "") + (if chkBitmap.checked then "\nVRayBitmap / VRayHDRI 已一并转为 Bitmap。" else "") + backupInfo )
            )
            catch
            (
                edtLog.text = ("转换出错：\n" + (try((getCurrentException()) as string)catch("未知错误")) + "\n\n请把此信息反馈给开发者。")
            )
            btnGo.enabled = true
            gc()
        )

        on btnRestore pressed do
        (
            local p = gBackupPath
            if p == "" or p == undefined do p = getOpenFileName caption:"选择材质备份文件" types:"Material Library (*.mat)|*.mat"
            if p == "" or p == undefined do ( edtLog.text = "未找到备份文件。\n请确认之前转换时勾选了「自动备份」，或手动选择 .mat 备份文件。" ; return false )
            if not (doesFileExist p) do ( edtLog.text = "备份文件不存在：\n" + p ; return false )
            undo "Restore Materials from Backup" on
            (
                if (restoreSceneMats p) then
                (
                    gBackupPath = p
                    edtLog.text = "已从备份恢复场景材质：\n" + p + "\n\n同名材质已覆盖还原。请检查材质编辑器与视口确认效果。"
                )
                else edtLog.text = "恢复失败：\n" + p + "\n\n可能原因：备份文件损坏，或当前场景与备份不匹配（材质名不一致）。\n\n可尝试手动恢复：\n1. 在 MAXScript 侦听器（F11）输入：\n   loadMaterialLibrary \"" + p + "\"\n2. 打开材质编辑器（M），把库中的材质手动拖回场景对象 / 材质槽位。"
            )
            gc()
        )

        on btnCount pressed do
        (
            local allMats  = collectAllMaterials()
            local vrayMats = for m in allMats where matchPattern (classof m as string) pattern:"VRay*" collect m
            local stdMats  = for m in allMats where classof m == StandardMaterial collect m
            local phyMats  = for m in allMats where classof m == PhysicalMaterial collect m
            edtLog.text = ( "统计结果：\n\n场景材质总数：" + allMats.count as string + "\nV-Ray 材质数：" + vrayMats.count as string + "\nStandard 材质数：" + stdMats.count as string + "\nPhysical 材质数：" + phyMats.count as string + "\n\n点击「开始替换」将" + (if chkAll.checked then "统一转换全部材质为 " else "把 V-Ray 材质转为 ") + (if (rdoTarget.state == 2 and canPhysical) then "Physical。" else "Standard。") + "\n\n提示：勾选「统一转换所有材质」可同时处理 Standard/Physical 互转。" )
        )
    )


    -- ===================== 面板二：程序贴图烘焙（FBX 导出兼容） =====================
    rollout rlBake "② 程序贴图烘焙（FBX 兼容）" width:340 height:320
    (
        edittext     edtDir   "输出目录:" text:"" width:250
        button       btnBrowse "浏览..." width:60 height:21
        dropdownList ddlSize  "烘焙分辨率:" items:#("512 × 512", "1024 × 1024", "2048 × 2048") selection:2
        checkbox     chkReplace "烘焙后替换原槽位（程序贴图 → 位图）" checked:true
        button       btnGo    "烘焙程序贴图" width:310 height:36
        edittext     edtLog   "" width:310 height:140 readOnly:true

        -- 默认输出目录：跟随当前打开的工程（open/btnGo 时实时计算，切换工程自动跟随）
        on rlBake open do (
            gLastBakeDefault = (sceneBaseDir() + "_baked_maps")
            edtDir.text = gLastBakeDefault
        )

        on btnBrowse pressed do (
            local d = getSavePath caption:"选择烘焙输出目录" initialDir:(sceneBaseDir())
            if d != undefined do edtDir.text = d
        )

        on btnGo pressed do
        (
            local dir = edtDir.text
            -- 跟随工程目录：输入为空或仍是上次自动默认值（用户未手动改）→ 刷新为当前工程目录
            if dir == undefined or dir == "" or dir == gLastBakeDefault do (
                dir = (sceneBaseDir() + "_baked_maps")
                edtDir.text = dir
            )
            -- 确保输出目录存在
            if not (doesDirectoryExist dir) do (
                try ( makeDir dir all:true ) catch ()
            )
            if not (doesDirectoryExist dir) do ( edtLog.text = "输出目录不可用：\n" + dir; return false )

            local sizeVal = case ddlSize.selection of (
                1: 512
                2: 1024
                3: 2048
                default: 1024
            )

            -- 收集场景全部材质 → 收集其中的程序贴图
            local mats = collectAllMaterials()
            local procMaps = collectProcMaps mats

            if procMaps.count == 0 do ( edtLog.text = "未发现程序贴图（全部已是 BitmapTexture）。\n无需烘焙。" ; return false )

            local okCount = 0
            local failCount = 0
            local logLines = #("发现程序贴图 " + (procMaps.count as string) + " 个，开始烘焙…")
            for item in procMaps do
            (
                local tm = item[1]
                local ownerMtl = item[2]
                local slotIdx = item[3]
                local mName = (try(tm.name)catch("map")) as string
                if chkReplace.checked then (
                    if (bakeAndReplace tm ownerMtl slotIdx dir sizeVal) then ( okCount += 1 ) else ( failCount += 1; append logLines ("失败: " + mName) )
                ) else (
                    -- 不替换：只烘焙文件
                    if (bakeOnly tm dir sizeVal) then ( okCount += 1 ) else ( failCount += 1; append logLines ("失败: " + mName) )
                )
            )
            append logLines ("完成：成功 " + (okCount as string) + " 个，失败 " + (failCount as string) + " 个")
            append logLines ("输出目录：" + dir)
            append logLines ("提示：若勾选了「替换」，FBX 导出时程序贴图即被位图替代，其他软件可正常显示。")
            edtLog.text = (joinStr logLines "\n")
            -- 打开目录方便查看
            try ( ShellLaunch dir "" ) catch ()
            gc()
        )
    )

    -- ===================== 面板三：导出材质构成 MD =====================
    rollout rlExport "③ 导出材质构成 MD" width:340 height:510
    (
        edittext     edtPath  "输出路径:" text:"" width:250
        button       btnBrowse "浏览..." width:60 height:21
        checkbox     chkObjs  "包含「使用对象」列表" checked:true
        checkbox     chkMaps  "包含「贴图」详情"     checked:true
        checkbox     chkParams "包含「数值/颜色」参数" checked:true
        button       btnCopy  "复制 AI 提示词（给 ChatGPT/Claude）" width:310 height:24
        button       btnGo    "导出材质构成 MD" width:310 height:36
        edittext     edtLog   "" width:310 height:240 readOnly:true

        -- 默认导出路径：跟随当前打开的工程（open/btnGo 时实时计算，切换工程自动跟随）
        on rlExport open do (
            gLastExportDefault = (sceneBaseDir() + "材质构成报告.md")
            edtPath.text = gLastExportDefault
        )

        on btnBrowse pressed do (
            local p = getSaveFileName caption:"保存材质构成报告" types:"Markdown (*.md)|*.md|All Files (*.*)|*.*" fileName:(sceneBaseDir() + "材质构成报告.md")
            if p != undefined do edtPath.text = p
        )

        on btnCopy pressed do (
            try (
                (dotNetClass "System.Windows.Forms.Clipboard").SetText aiPrompt
                edtLog.text = "AI 提示词已复制到剪贴板，直接粘贴给 ChatGPT / Claude 即可。"
            ) catch (
                edtLog.text = "提示词复制到剪贴板失败，可直接从导出 MD 的开头复制：\n\n" + aiPrompt
            )
        )


        on btnGo pressed do
        (
            local p = edtPath.text
            -- 跟随工程目录：输入为空或仍是上次自动默认值（用户未手动改）→ 刷新为当前工程目录
            if p == undefined or p == "" or p == gLastExportDefault do (
                p = (sceneBaseDir() + "材质构成报告.md")
                edtPath.text = p
            )
            if p == "" or p == undefined do ( messageBox "请先设置输出路径。" title:"提示"; return false )
            try
            (
                exportDoc p chkObjs.checked chkMaps.checked chkParams.checked
                edtLog.text = "已导出：\n" + p
                -- 打开所在文件夹，方便查看
                try ( ShellLaunch (getFilenamePath p) "" ) catch ()
            )
            catch
            (
                local errMsg = try ( getExceptionMessage() ) catch ( try ( (getCurrentException()) as string ) catch ( "未知错误" ) )
                local stage = try ( gExpStage as string ) catch ( "(无阶段信息)" )
                -- [DEBUG] 完整异常文本 + 调用栈（3ds Max 2017+ 支持 getCurrentExceptionStackTrace）
                local fullExc = try ( (getCurrentException()) as string ) catch ( "(无 getCurrentException)" )
                local stackTrace = try ( getCurrentExceptionStackTrace() ) catch ( "(无调用栈可用)" )
                format "[EXPORT ERROR] stage=%\n  msg=%\n  fullExc=%\n  stack=%\n" stage errMsg fullExc stackTrace
                edtLog.text = ("导出失败 @ " + stage + "：\n" + errMsg + "\n\n--- 完整异常 ---\n" + fullExc + "\n\n--- 调用栈 ---\n" + stackTrace + "\n\n（请检查输出路径是否可写，建议先保存到本机磁盘）")
            )
        )
    )
    -- ===================== 主窗口 =====================
    try ( destroyDialog matToolkit ) catch ()
    matToolkit = newRolloutFloater "材质工具箱 v3" 360 860
    addRollout rlVRayReplace matToolkit
    addRollout rlBake matToolkit
    addRollout rlExport matToolkit
)
