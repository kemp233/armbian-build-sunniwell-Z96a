-- Z96A: rk809 扬声器 (alsa card 1) 默认输出, 优先级压过 HDMI。
-- GNOME 音量滑杆 / 声音设置默认控它; 播放路径由 amixer_enspk1.service
-- 在开机时把 'Playback Path' 设成 SPK。
rule = {
  matches = {
    { { "node.name", "equals", "alsa_output.platform-rk809-sound.stereo-fallback" } },
  },
  apply_properties = {
    ["priority.driver"]  = 2000,
    ["priority.session"] = 2000,
  },
}
table.insert(alsa_monitor.rules, rule)
