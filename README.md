# Kindle SimpleUI + Z-Library 集成

基于 [doctorhetfield-cmd/simpleui.koplugin](https://github.com/doctorhetfield-cmd/simpleui.koplugin) 新增了 Z-Library 中文代理站点集成功能。

## 功能特性

- 🔍 **搜索图书** — 输入书名/作者搜索，支持翻页
- 📖 **图书详情** — 标题、作者、格式、简介、下载
- 🔐 **账号登录** — 多域名支持（z-lib.org / singlelogin.re / z-library.sk），Cookie 持久化
- 📥 **下载阅读** — 下载到书库子目录，完成后可直接打开阅读
- ⚡ **快捷操作** — 注册为 Quick Action 和手势动作

## 文件结构

```
simpleui.koplugin/
├── _meta.lua
├── main.lua
├── sui_*.lua
├── desktop_modules/
│   └── module_zlibrary.lua   — 主屏幕模块
├── icons/
│   ├── zlibrary.svg           — 图标
│   └── wechat-qr.png          — 微信公众号二维码
├── locale/
│   └── zh_CN.po               — 中文翻译
├── zlibrary/                  ← 新增
│   ├── zl_config.lua          — 配置管理（域名列表、Cookie、下载路径）
│   ├── zl_client.lua          — HTTP 客户端（登录/搜索/下载）
│   ├── zl_parser.lua          — HTML 解析器
│   └── zl_ui.lua              — UI 界面（搜索/详情/登录/设置/下载）
└── ...
```

## 安装部署指南

### 前提条件
- Kindle 设备已越狱并安装 [KOReader](https://github.com/koreader/koreader)
- KOReader 已安装 SimpleUI 插件（大部分 KOReader 发行版自带）

### 步骤 1：下载

**方式 A：直接下载 ZIP**
1. 打开 [githubmissyang/kindle_simpleui](https://github.com/githubmissyang/kindle_simpleui)
2. 点击绿色 **Code** 按钮 → **Download ZIP**
3. 解压 ZIP 文件

**方式 B：Git Clone**
```bash
git clone https://github.com/githubmissyang/kindle_simpleui.git
```

### 步骤 2：备份原有插件

USB 连接 Kindle 到电脑，找到 KOReader 插件目录：

| 设备 | 路径 |
|------|------|
| Kindle | `/mnt/us/koreader/plugins/simpleui.koplugin/` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/simpleui.koplugin/` |
| Android | KOReader 数据目录下 `plugins/simpleui.koplugin/` |

将原有的 `simpleui.koplugin` 文件夹重命名为 `simpleui.koplugin.bak` 作为备份。

### 步骤 3：部署

将下载的仓库中 `simpleui.koplugin/` 文件夹内**所有文件**复制到插件目录：

> ⚠️ 是**替换文件夹内的文件**，不是替换整个文件夹。确保原有的 `scripts/`、`.github/` 等目录也保留。

### 步骤 4：启用 Z-Library 模块

1. 重启 KOReader
2. 打开 SimpleUI 主屏幕
3. 长按主屏幕空白处 → **Arrange Modules** → 找到 **Z-Library** → 开启
4. 返回主屏幕，即可看到 Z-Library 搜索栏

### 步骤 5：登录 Z-Library

1. 点击主屏幕的 Z-Library 搜索栏 → 系统会提示未登录
2. 输入你的 Z-Library 邮箱和密码
3. 如需切换域名，点击 **切换域名** 按钮
4. 登录成功后即可搜索和下载图书

## 使用说明

| 操作 | 方法 |
|------|------|
| 搜索图书 | 点击主屏幕 Z-Library 搜索栏，或快捷操作中的 Z-Library 按钮 |
| 翻页 | 搜索结果底部有「上一页」「下一页」按钮 |
| 查看详情 | 点击搜索结果中的某本书 |
| 下载图书 | 在图书详情页点击「下载」按钮 |
| 下载后阅读 | 下载完成弹窗中点击「阅读」 |
| 打开已下载的书 | 点击主屏幕最近下载列表中的书名 |
| 模块设置 | 长按 Z-Library 模块区域 |
| 切换域名 | 设置菜单 → 域名选择 |
| 退出登录 | 设置菜单 → 点击已登录账号 → 确认退出 |

## 常见问题

**Q：搜索失败/网络错误？**
A：确保 Kindle 已连接 Wi-Fi。部分域名可能需要科学上网，尝试在设置中切换其他域名。

**Q：登录失败？**
A：确认邮箱和密码正确。Z-Library 免费账号有每日下载限额。

**Q：下载的书在哪里？**
A：默认在 KOReader 书库的 `Z-Library/` 子目录下，可在设置中修改。

**Q：如何恢复原版 SimpleUI？**
A：删除部署的文件，将 `simpleui.koplugin.bak` 重命名回 `simpleui.koplugin` 即可。

---

## 开发者

**AI架构师老杨**

微信公众号：**AI架构师之路**

<img src="simpleui.koplugin/icons/wechat-qr.png" width="200" alt="AI架构师之路 微信公众号二维码" />

关注公众号获取更多 AI + 开发相关内容。
