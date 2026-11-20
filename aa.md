# aa.md · 预览测试文件

这是一个用于测试 **Pi Go 工作区文件预览** 的 Markdown 文件。

## 基本格式

- **粗体** / *斜体* / `行内代码`
- 有序列表:
  1. 打开底部「工作区」标签
  2. 找到 `aa.md`
  3. 点开预览

> 引用块:侧边栏已支持打开时定位到当前会话所在的工作区位置。

## 代码块

```ts
// 侧边栏定位核心逻辑(harmony/entry/src/main/ets/pages/Index.ets)
private revealLibraryAnchor(): void {
  if (!this.pendingLibraryReveal || !this.showSessions || this.libraryViewportY < 0) return;
  const anchor: number = this.libraryRowY >= 0 ? this.libraryRowY : this.librarySpaceY;
  if (anchor < 0) return;
  this.library.scrollTo({ xOffset: 0, yOffset: Math.max(0, anchor - this.libraryViewportY - 8), animation: false });
}
```

## 表格

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 抽屉打开定位 | ✅ | 锚定当前会话行 |
| 工作区分组兜底 | ✅ | 会话不在列表时定位分组头 |
| 防抢滚动 | ✅ | 用户先滚动则取消定位 |

## 分隔线与链接

---

工程文档见 [PLAN.md](PLAN.md),桌面端桥接见 `desktop/broker.mjs`。

Emoji 测试:🚀 📱 ✅ 🔧(如果你在预览里能看到这些,说明 UTF-8 解码正常)
