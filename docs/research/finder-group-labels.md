# Finder 分组标签 —— 来自 Finder 自己的字符串表

Finder 没有源码，但它的本地化字符串表在本机：
`/System/Library/CoreServices/Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings`
（以及同目录的 `.loctable`）。分组用的键都带 `GROUP_` / `GV` 前缀。摘录（macOS 26.5）：

## 日期（四个日期键共用）

| 键 | 值 |
|---|---|
| `GROUP_TODAY` | Today |
| `GROUP_YESTERDAY` | Yesterday |
| `GROUP_PREVIOUS7DAYS` | Previous ^0 Days |
| `GROUP_PREVIOUS30DAYS` | Previous ^0 Days |
| `GROUP_EARLIER` | Earlier（用途待确认；我们对更早的日期用月名/年份） |
| `GROUP_FUTURE` | **No Date**（未来时间戳归此组，不进 Today） |

## 种类（Kind）

`GROUP_APPLICATIONS` Applications · `GROUP_DOCUMENTS` Documents · `GROUP_DIRECTORIES` Folders · `GROUP_IMAGES` Images · `GROUP_MOVIES` Movies · `GROUP_MUSIC` Music · `GROUP_PDF` PDF Documents · `GROUP_PRESENTATIONS` Presentations · `GROUP_SPREADSHEETS` Spreadsheets · `GROUP_TEXT` Text · `GROUP_SOURCE` Source code · `GROUP_HTML` HTML · `GROUP_APPLESCRIPT` AppleScript · `GROUP_FONTS` Fonts · `GROUP_CONTACT` Contacts · `GROUP_EMAIL` Mail Messages · `GROUP_BOOKMARKS` Webpages · `GROUP_FAXES` Faxes · `GROUP_EVENT_TODO` Events & To Do Items · `GROUP_RSS_ARTICLES` News Articles · `GROUP_SYSTEM_PREFS` System Settings · `GROUP_OTHER_DOCUMENTS` Other Documents · `GROUP_OTHER` Other

要点：**没有 Archives / Disk Images 组**（压缩包归 Other）；纯文本是 **Text**；代码是 **Source code**。这套类别和 Spotlight 经典的 kind 分组一致。组的顺序字符串表看不出来；我们按名称排序、不把 Folders 置顶。

## 大小

| 键 | 值 |
|---|---|
| `GV10` | Under ^0 |
| `GV11` | From ^0 to ^1 |
| `SP24`/`SP25`/`SP26`/`SP28` | GB / MB / KB / bytes |

分桶边界字符串表看不出来；按格式推断为十进制数量级：Under 1 KB、From 1 KB to 10 KB、From 10 KB to 100 KB、From 100 KB to 1 MB、…（1000 进制，与 Finder 显示大小一致）。

## 标签 / 其他

`GV12` No Tags · `GV7` Other · `GV6` Show Less · `GV_ALL_V1` Show All (^0)

## 未在字符串表中找到（仍是推断）

- Application 分组里"无默认应用"的标签（我们用 "No Application"）。
- 种类组的排序。
- Date Last Opened 用文件访问时间近似 Spotlight 的 last-used。
