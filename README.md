# Kindle SimpleUI 项目集合

本目录用于存放 Kindle/KOReader 相关的 GitHub 项目。

## 目录结构

```
kindle_simpleui/
├── repos/                          # GitHub 项目仓库
│   └── simpleui.koplugin/          # SimpleUI 主插件
└── README.md
```

## 项目列表

| 项目 | 源仓库 | 说明 |
|------|--------|------|
| simpleui.koplugin | [doctorhetfield-cmd/simpleui.koplugin](https://github.com/doctorhetfield-cmd/simpleui.koplugin) | KOReader 高度可定制的 UI 插件 |

## 本地分支说明

- `fix/zh-cn-translation` — 简体中文翻译完善 + Z-Library 中文代理站点集成

## Z-Library 功能

在 `fix/zh-cn-translation` 分支上新增了 Z-Library 集成功能：

### 文件结构
```
zlibrary/
├── zl_config.lua   — 配置管理（域名列表、Cookie、下载路径）
├── zl_client.lua   — HTTP 客户端（登录/搜索/下载）
├── zl_parser.lua   — HTML 解析器
└── zl_ui.lua       — UI 界面（搜索/详情/登录/设置/下载）
desktop_modules/module_zlibrary.lua  — 主屏幕模块
icons/zlibrary.svg                    — 图标
```

### 功能特性
- 🔍 **搜索图书** — 输入书名/作者搜索，支持翻页
- 📖 **图书详情** — 标题、作者、格式、简介、下载
- 🔐 **账号登录** — 多域名支持，Cookie 持久化
- 📥 **下载阅读** — 下载到书库子目录，完成后可直接打开阅读
- ⚡ **快捷操作** — 注册为 Quick Action 和手势动作
