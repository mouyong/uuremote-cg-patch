-- UU 重签期间的「钥匙串授权弹窗」自动应答器
-- ---------------------------------------------------------------------------
-- 为什么需要它：
--   给 UU 打补丁必须重签名，签名一变，之前授予「访问钥匙串密钥
--   com.netease.uuremote」的许可就失效。此后任何进程去读那把密钥，系统都会弹：
--     「…想要使用你存储在钥匙串的"com.netease.uuremote"中的机密信息。
--       若要给予许可，请输入"登录"钥匙串的密码。」
--   + 一个密码输入框，按钮：始终允许 / 拒绝 / 允许。
--   安装跑到一半卡在这里，远端/夜里没人点就停住了。
--
-- 注意（实测结论，别搞混）：
--   **解锁钥匙串 ≠ 授予 ACL 授权**。代码里 preunlock_login_keychain 只是把钥匙串
--   解锁（让签名能读到私钥），弹窗问的却是「这个 app 能不能读这把密钥」——
--   所以预解锁**不足以**消掉弹窗，每次重签后仍会弹。要在无人值守时装完，就得自动应答。
--
-- 用法（由 uu.sh 的 dialog_watcher_start 调起，一般不用手跑）：
--   osascript tools/uu-dialog-responder.applescript <口令文件> <最长轮询秒数>
--
-- 安全：口令只从本地文件读入内存、填进系统弹窗，不打印、不写日志、不入 git。
--       参数缺失或文件不存在 → 直接退出，绝不猜测或索取口令。
-- ---------------------------------------------------------------------------

on run argv
	if (count of argv) < 1 then return "no-pwfile"
	set pwFile to item 1 of argv
	set maxSecs to 90
	if (count of argv) ≥ 2 then
		try
			set maxSecs to (item 2 of argv) as integer
		end try
	end if

	-- 口令文件必须存在；否则不做事（不能编一个，也不该弹框要）
	try
		set pw to do shell script "cat " & quoted form of pwFile
	on error
		return "no-pwfile"
	end try
	if pw is "" then return "empty-pw"

	set handled to 0
	set ticks to maxSecs div 2  -- 每轮 2 秒

	repeat ticks times
		tell application "System Events"
			if exists (process "SecurityAgent") then
				tell process "SecurityAgent"
					try
						if (count of windows) > 0 then
							set w to window 1
							-- 只处理「要密码 + 有始终允许/允许」这种钥匙串授权框；
							-- 其它类型的系统弹窗（如要 Touch ID、要输管理密码）不碰，
							-- 免得把用户真正需要看的确认框顺手点掉。
							set btnNames to {}
							repeat with b in (every button of w)
								try
									set end of btnNames to (name of b)
								end try
							end repeat
							set isKeychainAsk to false
							try
								repeat with t in (every static text of w)
									set v to (value of t as string)
									if v contains "钥匙串" and (v contains "机密信息" or v contains "想要") then
										set isKeychainAsk to true
									end if
								end repeat
							end try

							if isKeychainAsk then
								-- 填密码（先点一下输入框拿到焦点）
								try
									click text field 1 of w
									delay 0.3
									keystroke pw
									delay 0.3
								end try
								-- 「始终允许」优先：一次授权后续不再打扰
								if btnNames contains "始终允许" then
									click button "始终允许" of w
									set handled to handled + 1
								else if btnNames contains "允许" then
									click button "允许" of w
									set handled to handled + 1
								end if
							end if
						end if
					end try
				end tell
			end if
		end tell
		delay 2
	end repeat

	return "handle-count=" & handled
end run
