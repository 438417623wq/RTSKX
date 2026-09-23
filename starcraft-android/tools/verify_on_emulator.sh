#!/usr/bin/env bash
# 在安卓模拟器上无人值守验证「星海战火」APK：启动 → 安装 → 运行 → 进对局 → 截图 → 收日志
#
# 用法：bash tools/verify_on_emulator.sh
#
# 关键约束：模拟器进程容易被环境回收，所以整条链路必须写在一个脚本里一次跑完。

set +e

AVD_NAME="${AVD:-Medium_Phone_API_36.1}"
# ⚠️ 路径要和 export_presets.cfg / 实际导出命令一致。
#    预设里的 export_path 是 debug 包；release 包是导出时用命令行覆盖路径产出的。
APK="${APK:-F:/KF/XJ/starcraft-android/build/xinghai-zhanhuo-release.apk}"
PKG="com.xinghai.zhanhuo"
ACT="com.godot.game.GodotAppLauncher"     # 入口是别名，不是 GodotApp
OUT_DIR="F:/KF/XJ/starcraft-android/shots"
WAIT_BOOT_S=45                            # 启动后等待渲染

ANDROID_SDK="${ANDROID_SDK:-$LOCALAPPDATA/Android/Sdk}"
EMU="$ANDROID_SDK/emulator/emulator.exe"
ADB="$ANDROID_SDK/platform-tools/adb.exe"

[ -f "$APK" ] || { echo "找不到 APK：$APK"; exit 1; }
mkdir -p "$OUT_DIR"

# 把逻辑坐标换算成屏幕像素。项目是 1280x720 + stretch=canvas_items/aspect=expand，
# 所以 scale = min(W/1280, H/720)，逻辑视口 = 物理尺寸 / scale。
# 不同机型分辨率不同，必须按实测的 wm size 算，不能写死。
to_px() {   # $1=逻辑x $2=逻辑y -> "屏幕x 屏幕y"
  awk -v x="$1" -v y="$2" -v s="$SCALE" 'BEGIN{printf "%d %d", int(x*s+0.5), int(y*s+0.5)}'
}

echo "== 启动模拟器（host GPU，避免软件渲染拖出 ANR）=="
"$ADB" kill-server >/dev/null 2>&1
"$ADB" start-server >/dev/null 2>&1
"$EMU" -avd "$AVD_NAME" -no-window -no-audio -no-boot-anim \
       -gpu host -no-snapshot -netdelay none -netspeed full \
       > "$OUT_DIR/emu.log" 2>&1 &
EMUPID=$!

echo "== 等待开机 =="
BOOTED=0
for i in $(seq 1 30); do
  sleep 10
  if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
    BOOTED=1; echo "   开机完成（约 $((i*10)) 秒）"; break
  fi
done
if [ "$BOOTED" != "1" ]; then
  echo "!! 开机超时，模拟器日志尾部："; tail -10 "$OUT_DIR/emu.log"
  kill $EMUPID 2>/dev/null; exit 1
fi

echo "== 关闭动画 + 抑制全屏提示 =="
for k in window_animation_scale transition_animation_scale animator_duration_scale; do
  "$ADB" shell settings put global "$k" 0 >/dev/null 2>&1
done
"$ADB" shell settings put secure immersive_mode_confirmations confirmed >/dev/null 2>&1

# ── 按实际分辨率算缩放 ───────────────────────────────────────────────
RAW=$("$ADB" shell wm size 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+x[0-9]+' | tail -1)
PW=${RAW%x*}; PH=${RAW#*x}
if [ "$PW" -lt "$PH" ]; then SW=$PH; SH=$PW; else SW=$PW; SH=$PH; fi   # 横屏
SCALE=$(awk -v w="$SW" -v h="$SH" 'BEGIN{s=w/1280; t=h/720; if(t<s)s=t; printf "%.6f", s}')
LW=$(awk -v w="$SW" -v s="$SCALE" 'BEGIN{printf "%.1f", w/s}')
LH=$(awk -v h="$SH" -v s="$SCALE" 'BEGIN{printf "%.1f", h/s}')
echo "   物理 ${SW}x${SH}  逻辑 ${LW}x${LH}  scale=${SCALE}"

# 菜单命中区（照 Main.gd 的 _draw_menu 公式算）：
#   开始按钮 = Rect2(LW*0.5-130, LH*0.36+178+58, 260, 54)
BTN=$(to_px "$(awk -v w="$LW" 'BEGIN{printf "%.1f", w*0.5}')" \
             "$(awk -v h="$LH" 'BEGIN{printf "%.1f", h*0.36+178+58+27}')")
#   阵营卡 terran = Rect2(LW*0.5-337, LH*0.36, 210, 150) 的中心
CARD=$(to_px "$(awk -v w="$LW" 'BEGIN{printf "%.1f", w*0.5-337+105}')" \
             "$(awk -v h="$LH" 'BEGIN{printf "%.1f", h*0.36+75}')")
echo "   开始按钮 @ $BTN    阵营卡 @ $CARD"

echo "== 安装 APK =="
"$ADB" install -r -t "$APK" 2>&1 | tail -2

echo "== 启动应用 =="
"$ADB" logcat -c >/dev/null 2>&1
"$ADB" shell am start -n "$PKG/$ACT" 2>&1 | tail -2
sleep "$WAIT_BOOT_S"

# 关掉可能的系统 ANR 弹窗（点 Wait）。注意：绝不发 KEYCODE_BACK，会直接退出 Godot。
"$ADB" shell input tap 716 667 >/dev/null 2>&1; sleep 2

echo "== 截图：菜单 =="
"$ADB" exec-out screencap -p > "$OUT_DIR/emu_01_menu.png" 2>/dev/null
echo "   $(stat -c%s "$OUT_DIR/emu_01_menu.png" 2>/dev/null) 字节"

echo "== 点「开始战斗」=="
"$ADB" shell input tap $BTN
sleep 30
"$ADB" exec-out screencap -p > "$OUT_DIR/emu_02_game.png" 2>/dev/null
echo "   $(stat -c%s "$OUT_DIR/emu_02_game.png" 2>/dev/null) 字节"

echo "== 再等 60 秒让基地发展起来 =="
sleep 60
"$ADB" exec-out screencap -p > "$OUT_DIR/emu_03_late.png" 2>/dev/null
echo "   $(stat -c%s "$OUT_DIR/emu_03_late.png" 2>/dev/null) 字节"

echo "== 进程状态 =="
PID=$("$ADB" shell pidof "$PKG" 2>/dev/null | tr -d '\r')
if [ -z "$PID" ]; then echo "!! 进程不存在，应用已退出"; else echo "   PID=$PID"; fi

echo "== 前台 Activity =="
"$ADB" shell dumpsys activity activities 2>/dev/null | grep -m1 "topResumedActivity" | tr -d '\r'

echo "== Godot 引擎日志（成功标志：OnGodotSetupCompleted / OnGodotMainLoopStarted）=="
"$ADB" logcat -d 2>/dev/null | grep -E "Godot  :|Godot:" | tail -20

echo "== 收工 =="
"$ADB" emu kill >/dev/null 2>&1
kill $EMUPID 2>/dev/null
echo "完成。截图在 $OUT_DIR"
