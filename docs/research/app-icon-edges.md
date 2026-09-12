# 应用图标的方形边缘

用户截图显示应用图标带着突兀的方形外沿；本地旧 PNG / ICNS 的外角也是不透明像素。这是本轮修复的直接依据。旧提示词把背景画满方形画布，并假设系统会再裁圆角；这不能作为当前手工打包 `.icns` 的交付规则。

## 管线与修复

Tursora 使用 `CFBundleIconFile` 指向打包的 `AppIcon.icns`。Apple 的 [Icon Composer 文档](https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer) 描述分层图形加入 Icon Composer / Xcode、由该管线生成各平台与外观资源的流程。该文档中的自动裁切说明适用于其所述流程；本应用没有采用该管线，不能据此推断手工交付的不透明 `.icns` 会自动得到同样处理。

本轮保留原双窗格尾鳍图案与渐变，改为可重复的导出：

- `app/Resources/AppIcon-artwork.png` 保存原方形画稿，前景比例和位置不变。
- `app/tools/render-icon.swift` 用 CoreGraphics 在透明的 1024 × 1024 画布上裁出一个圆角底板：矩形原点 `(80, 80)`，宽高均为 `864`，范围到 `(944, 944)`，两个圆角半径均为 `192`。图案仍按整个 1024 × 1024 画布绘制，只裁外部背景；无新增描边、阴影或第二层底板。
- 生成的 `app/Resources/AppIcon.png` 带透明外边距、透明角区和抗锯齿边界。上述尺寸是本应用的导出选择，不宣称等于 Apple 的系统遮罩曲线。
- `app/tools/make-icon.sh` 先重新导出 PNG，再用 `sips` / `iconutil` 生成 16–1024 px 图标族。`make-app.sh` 在 Swift 构建前调用它，每次打包都从原画重新生成资源，再复制生成后的 `AppIcon.icns`；README 和产品页使用同一份透明 PNG。
- 产品页的品牌、首屏和下载区图标移除矩形 CSS 边框、`box-shadow` 与 `border-radius`，改用跟随 PNG alpha 的 `drop-shadow`，避免透明导出又被网页样式套上方形外框。

修复过程中曾尝试两次图像生成编辑，但输出的 alpha 边缘有残留，均未采用或加入发布资源。最终资源由保存的原画与确定的裁切几何生成。历史提示词保留在 `app/Resources/icon-prompt.txt`，已明确标记过时的自动遮罩假设。

## 验证状态

- 已完成：定位用户截图与旧图标的不透明边角问题；核对当前导出脚本和打包路径。
- 最终站点静态构建已通过：5 个资源、36 个引用；桌面 1280 × 720 与窄屏 390 × 844 已观察图标，无额外方框。更新应用截图后再次检查页面与图片弹窗：图片比例正确，关闭后焦点返回，窄屏无横向溢出。
- 已实现回归：`IconAssetsSmokeTests` 解码实际 PNG / ICNS，归一化像素布局后检查 1024 px 尺寸、整圈透明外沿、四角透明、主体不透明及内缩范围、部分 alpha 边缘，并逐个检查 ICNS 表示的透明角、中心和尺寸覆盖。检查不依赖原位 bitmap 字节顺序，也不将具体半径作为产品不可变常量。
- 完整 smoke：**1,500 项连续三轮通过**，均 exit 0、stderr 为空。日志位于 `/private/tmp/tursora-pane-tabs-verification/final/smoke-{1,2,3}.{out,err}`；测试后源码哈希未改变。
- 最终 release 构建成功，strict codesign、Info.plist lint 与嵌入 ICNS 一致性检查通过。ICNS SHA-256：`4a3b178240c5c5559ddb59793ab1e27a8c5ab5f0775ace3aa380bfaef621b7b4`。
- 实机：在已打包应用中打开其 `app/build` 目录，以图标视图显示 `Tursora.app`，实际系统图标读取路径呈现透明外沿和顺滑圆角，无旧方形边框。该观察验证当前发布包图标，不等同于验证其他已安装副本或 Dock 的历史缓存。测试应用已退出，偏好与目录视图库已恢复，共享验证锁已释放。

![打包应用实际加载的圆角透明图标](../images/features/app-icon-edges.png)
